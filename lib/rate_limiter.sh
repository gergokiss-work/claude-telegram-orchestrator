#!/bin/bash
# Rate Limiter Library for RALPH Worker
# Tracks API calls per hour and enforces limits
#
# Usage:
#   source lib/rate_limiter.sh
#   rl_init "session"
#   rl_can_call "session" && echo "OK to call"
#   rl_record_call "session"
#   rl_wait_for_reset "session"

# Configuration
RL_MAX_CALLS_PER_HOUR=${RL_MAX_CALLS_PER_HOUR:-100}
RL_STATE_DIR="${RL_STATE_DIR:-$HOME/.claude/telegram-orchestrator/worker-state}"

#
# Internal helpers
#

_rl_state_file() {
    local session=$1
    echo "$RL_STATE_DIR/$session/rate_limit.json"
}

_rl_ensure_dir() {
    local session=$1
    mkdir -p "$RL_STATE_DIR/$session"
}

_rl_get_hour() {
    date +%Y%m%d%H
}

#
# Core Functions
#

# Initialize rate limiter
rl_init() {
    local session=$1
    _rl_ensure_dir "$session"

    local state_file=$(_rl_state_file "$session")
    local current_hour=$(_rl_get_hour)

    if [[ -f "$state_file" ]]; then
        # Check if we need to reset for new hour
        local stored_hour=$(jq -r '.hour // ""' "$state_file" 2>/dev/null)
        if [[ "$stored_hour" == "$current_hour" ]]; then
            return 0  # Same hour, keep state
        fi
    fi

    # New hour or no state, initialize
    cat > "$state_file" << EOF
{
    "hour": "$current_hour",
    "calls": 0,
    "max_calls": $RL_MAX_CALLS_PER_HOUR,
    "first_call_at": null,
    "last_call_at": null
}
EOF
}

# Check if a call can be made
rl_can_call() {
    local session=$1
    rl_init "$session"

    local state_file=$(_rl_state_file "$session")
    local current_hour=$(_rl_get_hour)

    # Check if hour changed (auto-reset)
    local stored_hour=$(jq -r '.hour' "$state_file" 2>/dev/null)
    if [[ "$stored_hour" != "$current_hour" ]]; then
        rl_init "$session"  # Reset for new hour
        return 0
    fi

    local calls=$(jq -r '.calls // 0' "$state_file" 2>/dev/null)
    local max_calls=$(jq -r '.max_calls // 100' "$state_file" 2>/dev/null)

    [[ $calls -lt $max_calls ]]
}

# Record a call
rl_record_call() {
    local session=$1
    rl_init "$session"

    local state_file=$(_rl_state_file "$session")
    local current_hour=$(_rl_get_hour)
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Check if hour changed
    local stored_hour=$(jq -r '.hour' "$state_file" 2>/dev/null)
    if [[ "$stored_hour" != "$current_hour" ]]; then
        rl_init "$session"
    fi

    # Read current state
    local state=$(cat "$state_file")
    local calls=$(echo "$state" | jq -r '.calls // 0')
    local first_call=$(echo "$state" | jq -r '.first_call_at')

    # Update
    calls=$((calls + 1))
    [[ "$first_call" == "null" ]] && first_call="$timestamp"

    cat > "$state_file" << EOF
{
    "hour": "$current_hour",
    "calls": $calls,
    "max_calls": $RL_MAX_CALLS_PER_HOUR,
    "first_call_at": "$first_call",
    "last_call_at": "$timestamp"
}
EOF
}

# Get remaining calls
rl_get_remaining() {
    local session=$1
    rl_init "$session"

    local state_file=$(_rl_state_file "$session")
    local current_hour=$(_rl_get_hour)

    # Check if hour changed
    local stored_hour=$(jq -r '.hour' "$state_file" 2>/dev/null)
    if [[ "$stored_hour" != "$current_hour" ]]; then
        echo "$RL_MAX_CALLS_PER_HOUR"
        return
    fi

    local calls=$(jq -r '.calls // 0' "$state_file" 2>/dev/null)
    local max_calls=$(jq -r '.max_calls // 100' "$state_file" 2>/dev/null)

    echo $((max_calls - calls))
}

# Get seconds until reset
rl_get_seconds_until_reset() {
    local current_minute=$(date +%M)
    local current_second=$(date +%S)

    # Remove leading zeros to avoid octal interpretation
    current_minute=$((10#$current_minute))
    current_second=$((10#$current_second))

    echo $(( (60 - current_minute - 1) * 60 + (60 - current_second) ))
}

# Wait for rate limit reset with countdown
rl_wait_for_reset() {
    local session=$1
    local silent=${2:-false}

    local wait_time=$(rl_get_seconds_until_reset)

    if [[ "$silent" != "true" ]]; then
        echo "Rate limit reached. Waiting $wait_time seconds for reset..."
    fi

    while [[ $wait_time -gt 0 ]]; do
        if [[ "$silent" != "true" ]]; then
            local mins=$((wait_time / 60))
            local secs=$((wait_time % 60))
            printf "\rTime until reset: %02d:%02d" $mins $secs
        fi
        sleep 1
        wait_time=$((wait_time - 1))
    done

    if [[ "$silent" != "true" ]]; then
        printf "\n"
        echo "Rate limit reset!"
    fi

    # Reinitialize for new hour
    rl_init "$session"
}

# Get rate limit status
rl_get_status() {
    local session=$1
    rl_init "$session"

    local state_file=$(_rl_state_file "$session")
    cat "$state_file" 2>/dev/null || echo '{"error": "no state"}'
}

# Show rate limit status
rl_show_status() {
    local session=$1
    local state=$(rl_get_status "$session")

    local calls=$(echo "$state" | jq -r '.calls // 0')
    local max_calls=$(echo "$state" | jq -r '.max_calls // 100')
    local remaining=$((max_calls - calls))
    local reset_in=$(rl_get_seconds_until_reset)
    local mins=$((reset_in / 60))
    local secs=$((reset_in % 60))

    echo "╔══════════════════════════════════════════════════╗"
    echo "║         Rate Limiter: $session"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║ Calls Used:    $calls / $max_calls"
    echo "║ Remaining:     $remaining"
    echo "║ Reset In:      ${mins}m ${secs}s"
    echo "╚══════════════════════════════════════════════════╝"
}

# Export functions
export -f rl_init rl_can_call rl_record_call rl_get_remaining
export -f rl_get_seconds_until_reset rl_wait_for_reset rl_get_status rl_show_status
