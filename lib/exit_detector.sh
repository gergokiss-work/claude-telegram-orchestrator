#!/bin/bash
# Exit Detector Library for RALPH Worker
# Multi-condition exit detection with dual-gate verification
#
# Usage:
#   source lib/exit_detector.sh
#   ed_check "session" && echo "Should exit"
#   ed_get_reason "session"

# Configuration
ED_MAX_TEST_LOOPS=${ED_MAX_TEST_LOOPS:-3}
ED_MAX_DONE_SIGNALS=${ED_MAX_DONE_SIGNALS:-2}
ED_COMPLETION_THRESHOLD=${ED_COMPLETION_THRESHOLD:-2}
ED_SAFETY_THRESHOLD=${ED_SAFETY_THRESHOLD:-5}  # Force exit after this many completion indicators
ED_STATE_DIR="${ED_STATE_DIR:-$HOME/.claude/telegram-orchestrator/worker-state}"

#
# Internal helpers
#

_ed_signals_file() {
    local session=$1
    echo "$ED_STATE_DIR/$session/exit_signals.json"
}

_ed_ensure_dir() {
    local session=$1
    mkdir -p "$ED_STATE_DIR/$session"
}

#
# Signal Tracking
#

# Initialize exit detector
ed_init() {
    local session=$1
    _ed_ensure_dir "$session"

    local signals_file=$(_ed_signals_file "$session")

    if [[ ! -f "$signals_file" ]] || ! jq -e '.' "$signals_file" >/dev/null 2>&1; then
        cat > "$signals_file" << EOF
{
    "test_only_loops": [],
    "done_signals": [],
    "completion_indicators": [],
    "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    fi
}

# Record signals from a loop
ed_record_signals() {
    local session=$1
    local loop_number=$2
    local is_test_only=$3        # true/false
    local has_done_signal=$4     # true/false
    local completion_count=$5    # integer

    ed_init "$session"
    local signals_file=$(_ed_signals_file "$session")
    local signals=$(cat "$signals_file")

    # Add to test_only_loops if applicable (keep last 10)
    if [[ "$is_test_only" == "true" ]]; then
        signals=$(echo "$signals" | jq ".test_only_loops += [$loop_number] | .test_only_loops = .test_only_loops[-10:]")
    else
        # Reset test loops if not test-only
        signals=$(echo "$signals" | jq ".test_only_loops = []")
    fi

    # Add to done_signals if applicable (keep last 10)
    if [[ "$has_done_signal" == "true" ]]; then
        signals=$(echo "$signals" | jq ".done_signals += [$loop_number] | .done_signals = .done_signals[-10:]")
    else
        # Reset done signals if no done signal
        signals=$(echo "$signals" | jq ".done_signals = []")
    fi

    # Add completion indicators (keep last 10)
    if [[ $completion_count -gt 0 ]]; then
        signals=$(echo "$signals" | jq ".completion_indicators += [$completion_count] | .completion_indicators = .completion_indicators[-10:]")
    else
        # Reset if no completion indicators this loop
        signals=$(echo "$signals" | jq ".completion_indicators = []")
    fi

    # Update timestamp
    signals=$(echo "$signals" | jq ".last_updated = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"")

    echo "$signals" > "$signals_file"
}

# Get recent test loop count
ed_get_test_loop_count() {
    local session=$1
    local signals_file=$(_ed_signals_file "$session")

    if [[ -f "$signals_file" ]]; then
        jq -r '.test_only_loops | length' "$signals_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Get recent done signal count
ed_get_done_signal_count() {
    local session=$1
    local signals_file=$(_ed_signals_file "$session")

    if [[ -f "$signals_file" ]]; then
        jq -r '.done_signals | length' "$signals_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Get total recent completion indicators
ed_get_completion_indicator_count() {
    local session=$1
    local signals_file=$(_ed_signals_file "$session")

    if [[ -f "$signals_file" ]]; then
        jq -r '.completion_indicators | add // 0' "$signals_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

#
# Task File Checking
#

# Check if all checkboxes in task file are complete
ed_check_task_file_complete() {
    local session=$1
    local task_file="$HOME/.claude/handoffs/${session}-task.md"

    if [[ ! -f "$task_file" ]]; then
        echo "no_task"
        return
    fi

    local total=$(grep -cE "^\s*- \[[ x]\]" "$task_file" 2>/dev/null || echo "0")
    local done=$(grep -cE "^\s*- \[x\]" "$task_file" 2>/dev/null || echo "0")

    if [[ $total -gt 0 && $done -eq $total ]]; then
        echo "complete"
    else
        echo "incomplete|$done/$total"
    fi
}

#
# Exit Condition Checking
#

# Check all exit conditions
# Returns: exit_reason or empty string
ed_check() {
    local session=$1
    local exit_signal=${2:-false}  # From response analyzer

    ed_init "$session"

    local reason=""

    # 1. Explicit EXIT_SIGNAL from Claude (highest priority)
    if [[ "$exit_signal" == "true" ]]; then
        local completion_count=$(ed_get_completion_indicator_count "$session")
        if [[ $completion_count -ge $ED_COMPLETION_THRESHOLD ]]; then
            reason="project_complete"
        else
            # EXIT_SIGNAL true but low completion indicators - trust Claude
            reason="explicit_exit_signal"
        fi
        echo "$reason"
        return 0
    fi

    # 2. All task file checkboxes complete
    local task_status=$(ed_check_task_file_complete "$session")
    if [[ "$task_status" == "complete" ]]; then
        reason="all_tasks_complete"
        echo "$reason"
        return 0
    fi

    # 3. Safety circuit breaker - too many completion indicators without EXIT_SIGNAL
    local completion_count=$(ed_get_completion_indicator_count "$session")
    if [[ $completion_count -ge $ED_SAFETY_THRESHOLD ]]; then
        reason="safety_completion_threshold"
        echo "$reason"
        return 0
    fi

    # 4. Too many test-only loops
    local test_loops=$(ed_get_test_loop_count "$session")
    if [[ $test_loops -ge $ED_MAX_TEST_LOOPS ]]; then
        reason="test_saturation"
        echo "$reason"
        return 0
    fi

    # 5. Multiple done signals
    local done_signals=$(ed_get_done_signal_count "$session")
    if [[ $done_signals -ge $ED_MAX_DONE_SIGNALS ]]; then
        reason="multiple_done_signals"
        echo "$reason"
        return 0
    fi

    # 6. Dual-gate: completion indicators + EXIT_SIGNAL (handled above, but catch edge cases)
    if [[ $completion_count -ge $ED_COMPLETION_THRESHOLD ]]; then
        # High completion indicators but EXIT_SIGNAL is false
        # Don't exit - Claude explicitly says more work needed
        echo ""
        return 1
    fi

    # No exit conditions met
    echo ""
    return 1
}

# Get human-readable exit reason description
ed_get_reason_description() {
    local reason=$1

    case "$reason" in
        "project_complete")
            echo "Project complete (EXIT_SIGNAL: true with completion indicators)" ;;
        "explicit_exit_signal")
            echo "Claude explicitly signaled exit (EXIT_SIGNAL: true)" ;;
        "all_tasks_complete")
            echo "All task file checkboxes are checked" ;;
        "safety_completion_threshold")
            echo "Safety: Too many completion indicators without EXIT_SIGNAL ($ED_SAFETY_THRESHOLD+)" ;;
        "test_saturation")
            echo "Test saturation: $ED_MAX_TEST_LOOPS+ consecutive test-only loops" ;;
        "multiple_done_signals")
            echo "Multiple done signals: $ED_MAX_DONE_SIGNALS+ in recent loops" ;;
        *)
            echo "Unknown reason: $reason" ;;
    esac
}

# Clear exit signals (for respawn/reset)
ed_clear() {
    local session=$1
    local signals_file=$(_ed_signals_file "$session")

    cat > "$signals_file" << EOF
{
    "test_only_loops": [],
    "done_signals": [],
    "completion_indicators": [],
    "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Show exit detector status
ed_show_status() {
    local session=$1

    local test_loops=$(ed_get_test_loop_count "$session")
    local done_signals=$(ed_get_done_signal_count "$session")
    local completion=$(ed_get_completion_indicator_count "$session")
    local task_status=$(ed_check_task_file_complete "$session")

    echo "╔══════════════════════════════════════════════════╗"
    echo "║         Exit Detector: $session"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║ Test-Only Loops:    $test_loops / $ED_MAX_TEST_LOOPS"
    echo "║ Done Signals:       $done_signals / $ED_MAX_DONE_SIGNALS"
    echo "║ Completion Ind:     $completion / $ED_SAFETY_THRESHOLD (safety)"
    echo "║ Task File:          $task_status"
    echo "╚══════════════════════════════════════════════════╝"
}

# Export functions
export -f ed_init ed_record_signals ed_get_test_loop_count ed_get_done_signal_count
export -f ed_get_completion_indicator_count ed_check_task_file_complete
export -f ed_check ed_get_reason_description ed_clear ed_show_status
