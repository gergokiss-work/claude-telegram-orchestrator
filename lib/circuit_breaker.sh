#!/bin/bash
# Circuit Breaker Library for RALPH Worker
# 3-state model: CLOSED → HALF_OPEN → OPEN
# Based on Michael Nygard's "Release It!" pattern
#
# Usage:
#   source lib/circuit_breaker.sh
#   cb_init "session-name"
#   cb_record_result "session" files_changed has_errors
#   cb_should_halt "session" && echo "HALT"
#   cb_reset "session"

# States
CB_CLOSED="CLOSED"           # Normal operation
CB_HALF_OPEN="HALF_OPEN"     # Testing recovery
CB_OPEN="OPEN"               # Halted, needs intervention

# Thresholds (configurable via environment)
CB_NO_PROGRESS_THRESHOLD=${CB_NO_PROGRESS_THRESHOLD:-3}
CB_SAME_ERROR_THRESHOLD=${CB_SAME_ERROR_THRESHOLD:-5}
CB_OUTPUT_DECLINE_THRESHOLD=${CB_OUTPUT_DECLINE_THRESHOLD:-70}
CB_HALF_OPEN_SUCCESS_THRESHOLD=${CB_HALF_OPEN_SUCCESS_THRESHOLD:-2}
CB_COMPLETION_INDICATOR_THRESHOLD=${CB_COMPLETION_INDICATOR_THRESHOLD:-5}

# Directory for state files
CB_STATE_DIR="${CB_STATE_DIR:-$HOME/.claude/telegram-orchestrator/worker-state}"

#
# Internal helpers
#

_cb_state_file() {
    local session=$1
    echo "$CB_STATE_DIR/$session/circuit.json"
}

_cb_ensure_dir() {
    local session=$1
    mkdir -p "$CB_STATE_DIR/$session"
}

_cb_log() {
    local session=$1
    local level=$2
    local msg=$3
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CB:$session] [$level] $msg"
}

#
# Core Functions
#

# Initialize circuit breaker for a session
cb_init() {
    local session=$1
    _cb_ensure_dir "$session"

    local state_file=$(_cb_state_file "$session")

    # Check if valid state exists
    if [[ -f "$state_file" ]]; then
        if jq -e '.' "$state_file" >/dev/null 2>&1; then
            return 0  # Already initialized and valid
        fi
        rm -f "$state_file"  # Corrupted, recreate
    fi

    # Create initial state
    cat > "$state_file" << EOF
{
    "state": "$CB_CLOSED",
    "last_change": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "consecutive_success_half_open": 0,
    "completion_indicators": 0,
    "last_progress_loop": 0,
    "last_error_hash": "",
    "last_output_length": 0,
    "total_opens": 0,
    "reason": "initialized"
}
EOF
    _cb_log "$session" "INFO" "Circuit breaker initialized"
}

# Get current state
cb_get_state() {
    local session=$1
    local state_file=$(_cb_state_file "$session")

    if [[ ! -f "$state_file" ]]; then
        echo "$CB_CLOSED"
        return
    fi

    jq -r '.state // "CLOSED"' "$state_file" 2>/dev/null || echo "$CB_CLOSED"
}

# Get full state as JSON
cb_get_full_state() {
    local session=$1
    local state_file=$(_cb_state_file "$session")

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo '{"state": "CLOSED"}'
    fi
}

# Record loop result and update state
# Args: session files_changed(int) has_errors(bool) output_length(int) error_hash(str) completion_indicators(int)
cb_record_result() {
    local session=$1
    local files_changed=${2:-0}
    local has_errors=${3:-false}
    local output_length=${4:-0}
    local error_hash=${5:-""}
    local completion_indicators=${6:-0}

    cb_init "$session"
    local state_file=$(_cb_state_file "$session")
    local state_data=$(cat "$state_file")

    # Extract current values
    local current_state=$(echo "$state_data" | jq -r '.state')
    local no_progress=$(echo "$state_data" | jq -r '.consecutive_no_progress // 0')
    local same_error=$(echo "$state_data" | jq -r '.consecutive_same_error // 0')
    local success_half_open=$(echo "$state_data" | jq -r '.consecutive_success_half_open // 0')
    local comp_indicators=$(echo "$state_data" | jq -r '.completion_indicators // 0')
    local last_error_hash=$(echo "$state_data" | jq -r '.last_error_hash // ""')
    local last_output=$(echo "$state_data" | jq -r '.last_output_length // 0')
    local total_opens=$(echo "$state_data" | jq -r '.total_opens // 0')

    # Detect progress
    local has_progress=false
    if [[ $files_changed -gt 0 ]]; then
        has_progress=true
        no_progress=0
    else
        no_progress=$((no_progress + 1))
    fi

    # Detect same error
    if [[ "$has_errors" == "true" ]]; then
        if [[ "$error_hash" == "$last_error_hash" && -n "$error_hash" ]]; then
            same_error=$((same_error + 1))
        else
            same_error=1
        fi
    else
        same_error=0
        error_hash=""
    fi

    # Track completion indicators (safety circuit)
    if [[ $completion_indicators -gt 0 ]]; then
        comp_indicators=$((comp_indicators + completion_indicators))
    else
        comp_indicators=0  # Reset if no completion indicators
    fi

    # Detect output decline
    local output_declined=false
    if [[ $last_output -gt 0 && $output_length -gt 0 ]]; then
        local decline_pct=$(( (last_output - output_length) * 100 / last_output ))
        if [[ $decline_pct -ge $CB_OUTPUT_DECLINE_THRESHOLD ]]; then
            output_declined=true
        fi
    fi

    # State machine transitions
    local new_state="$current_state"
    local reason=""

    case "$current_state" in
        "$CB_CLOSED")
            if [[ $no_progress -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
                new_state="$CB_OPEN"
                reason="No progress for $no_progress consecutive loops"
                total_opens=$((total_opens + 1))
            elif [[ $same_error -ge $CB_SAME_ERROR_THRESHOLD ]]; then
                new_state="$CB_OPEN"
                reason="Same error repeated $same_error times"
                total_opens=$((total_opens + 1))
            elif [[ "$output_declined" == "true" ]]; then
                new_state="$CB_OPEN"
                reason="Output declined by >$CB_OUTPUT_DECLINE_THRESHOLD%"
                total_opens=$((total_opens + 1))
            elif [[ $comp_indicators -ge $CB_COMPLETION_INDICATOR_THRESHOLD ]]; then
                new_state="$CB_OPEN"
                reason="Safety: $comp_indicators completion indicators without EXIT_SIGNAL"
                total_opens=$((total_opens + 1))
            elif [[ $no_progress -ge 2 ]]; then
                new_state="$CB_HALF_OPEN"
                reason="Monitoring: $no_progress loops without progress"
            fi
            ;;

        "$CB_HALF_OPEN")
            if [[ "$has_progress" == "true" ]]; then
                success_half_open=$((success_half_open + 1))
                if [[ $success_half_open -ge $CB_HALF_OPEN_SUCCESS_THRESHOLD ]]; then
                    new_state="$CB_CLOSED"
                    reason="Recovered after $success_half_open successful loops"
                    success_half_open=0
                else
                    reason="Recovery in progress: $success_half_open/$CB_HALF_OPEN_SUCCESS_THRESHOLD"
                fi
            elif [[ $no_progress -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
                new_state="$CB_OPEN"
                reason="No recovery: $no_progress loops without progress"
                total_opens=$((total_opens + 1))
                success_half_open=0
            fi
            ;;

        "$CB_OPEN")
            # Stay open until manual reset
            reason="Circuit is OPEN - manual reset required"
            ;;
    esac

    # Update state file
    cat > "$state_file" << EOF
{
    "state": "$new_state",
    "last_change": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "consecutive_no_progress": $no_progress,
    "consecutive_same_error": $same_error,
    "consecutive_success_half_open": $success_half_open,
    "completion_indicators": $comp_indicators,
    "last_error_hash": "$error_hash",
    "last_output_length": $output_length,
    "total_opens": $total_opens,
    "reason": "$reason"
}
EOF

    # Log state transition
    if [[ "$new_state" != "$current_state" ]]; then
        _cb_log "$session" "WARN" "State transition: $current_state → $new_state ($reason)"

        # Record in history
        local history_file="$CB_STATE_DIR/$session/circuit_history.json"
        if [[ ! -f "$history_file" ]]; then
            echo '[]' > "$history_file"
        fi

        local transition=$(cat << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "from": "$current_state",
    "to": "$new_state",
    "reason": "$reason"
}
EOF
)
        # Keep last 50 transitions
        jq --argjson t "$transition" '. += [$t] | .[-50:]' "$history_file" > "${history_file}.tmp" && mv "${history_file}.tmp" "$history_file"
    fi

    # Return exit code based on new state
    if [[ "$new_state" == "$CB_OPEN" ]]; then
        return 1
    fi
    return 0
}

# Check if execution should halt
cb_should_halt() {
    local session=$1
    local state=$(cb_get_state "$session")

    [[ "$state" == "$CB_OPEN" ]]
}

# Reset circuit breaker
cb_reset() {
    local session=$1
    local reason=${2:-"Manual reset"}

    _cb_ensure_dir "$session"
    local state_file=$(_cb_state_file "$session")

    local total_opens=0
    if [[ -f "$state_file" ]]; then
        total_opens=$(jq -r '.total_opens // 0' "$state_file" 2>/dev/null || echo "0")
    fi

    cat > "$state_file" << EOF
{
    "state": "$CB_CLOSED",
    "last_change": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "consecutive_success_half_open": 0,
    "completion_indicators": 0,
    "last_error_hash": "",
    "last_output_length": 0,
    "total_opens": $total_opens,
    "reason": "$reason"
}
EOF

    _cb_log "$session" "INFO" "Circuit breaker reset: $reason"
}

# Display circuit breaker status
cb_show_status() {
    local session=$1
    local state_file=$(_cb_state_file "$session")

    if [[ ! -f "$state_file" ]]; then
        echo "No circuit breaker state for $session"
        return 1
    fi

    local data=$(cat "$state_file")
    local state=$(echo "$data" | jq -r '.state')
    local reason=$(echo "$data" | jq -r '.reason')
    local no_progress=$(echo "$data" | jq -r '.consecutive_no_progress')
    local same_error=$(echo "$data" | jq -r '.consecutive_same_error')
    local total_opens=$(echo "$data" | jq -r '.total_opens')
    local last_change=$(echo "$data" | jq -r '.last_change')

    local icon="✅"
    [[ "$state" == "$CB_HALF_OPEN" ]] && icon="⚠️"
    [[ "$state" == "$CB_OPEN" ]] && icon="🚨"

    echo "╔══════════════════════════════════════════════════╗"
    echo "║         Circuit Breaker: $session"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║ State:        $icon $state"
    echo "║ Reason:       $reason"
    echo "║ No Progress:  $no_progress / $CB_NO_PROGRESS_THRESHOLD"
    echo "║ Same Error:   $same_error / $CB_SAME_ERROR_THRESHOLD"
    echo "║ Total Opens:  $total_opens"
    echo "║ Last Change:  $last_change"
    echo "╚══════════════════════════════════════════════════╝"
}

# Export for sourcing
export -f cb_init cb_get_state cb_get_full_state cb_record_result cb_should_halt cb_reset cb_show_status
