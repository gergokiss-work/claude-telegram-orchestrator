#!/bin/bash
# ralph-status.sh - Show status of all RALPH workers
#
# Usage:
#   ralph-status.sh              Show all workers
#   ralph-status.sh <session>    Show specific worker
#   ralph-status.sh --json       JSON output

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SCRIPT_DIR/worker-state"
HANDOFFS_DIR="$HOME/.claude/handoffs"

# Source libraries
source "$SCRIPT_DIR/lib/circuit_breaker.sh" 2>/dev/null
source "$SCRIPT_DIR/lib/rate_limiter.sh" 2>/dev/null
source "$SCRIPT_DIR/lib/exit_detector.sh" 2>/dev/null

show_worker_status() {
    local session=$1
    local json_mode=${2:-false}

    local state_file="$STATE_DIR/$session/state.json"
    local pid_file="$STATE_DIR/$session/worker.pid"

    if [[ ! -f "$state_file" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo '{"session": "'$session'", "status": "no_worker"}'
        else
            echo "No worker state for $session"
        fi
        return 1
    fi

    local state=$(cat "$state_file")
    local status=$(echo "$state" | jq -r '.status // "unknown"')
    local loops=$(echo "$state" | jq -r '.loop_count // 0')
    local started=$(echo "$state" | jq -r '.started_at // "unknown"')
    local last_loop=$(echo "$state" | jq -r '.last_loop_at // "never"')
    local files=$(echo "$state" | jq -r '.total_files_modified // 0')
    local task_file=$(echo "$state" | jq -r '.task_file // "unknown"')
    local exit_reason=$(echo "$state" | jq -r '.exit_reason // null')

    # Check if actually running
    local running="false"
    local pid=""
    if [[ -f "$pid_file" ]]; then
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            running="true"
        fi
    fi

    # Get component states
    local cb_state=$(cb_get_state "$session" 2>/dev/null || echo "unknown")
    local rate_remaining=$(rl_get_remaining "$session" 2>/dev/null || echo "unknown")

    # Get task progress
    local task_progress="N/A"
    if [[ -f "$task_file" ]]; then
        local total=$(grep -cE "^\s*- \[[ x]\]" "$task_file" 2>/dev/null || echo "0")
        local done=$(grep -cE "^\s*- \[x\]" "$task_file" 2>/dev/null || echo "0")
        task_progress="$done/$total"
    fi

    if [[ "$json_mode" == "true" ]]; then
        cat << EOF
{
    "session": "$session",
    "status": "$status",
    "running": $running,
    "pid": ${pid:-null},
    "loops": $loops,
    "files_modified": $files,
    "task_progress": "$task_progress",
    "circuit_breaker": "$cb_state",
    "rate_limit_remaining": $rate_remaining,
    "started_at": "$started",
    "last_loop_at": "$last_loop",
    "exit_reason": ${exit_reason:-null}
}
EOF
    else
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║ RALPH Worker: $session"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║ Status:          $status"
        [[ "$running" == "true" ]] && echo "║ Running:         Yes (PID: $pid)" || echo "║ Running:         No"
        echo "║ Loops:           $loops"
        echo "║ Files Modified:  $files"
        echo "║ Task Progress:   $task_progress"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║ Circuit Breaker: $cb_state"
        echo "║ Rate Remaining:  $rate_remaining/hour"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║ Started:         $started"
        echo "║ Last Loop:       $last_loop"
        [[ "$exit_reason" != "null" ]] && echo "║ Exit Reason:     $exit_reason"
        echo "╚══════════════════════════════════════════════════════════════╝"
    fi
}

show_all_workers() {
    local json_mode=${1:-false}

    if [[ "$json_mode" == "true" ]]; then
        echo "["
        local first=true
        for state_dir in "$STATE_DIR"/*/; do
            [[ ! -d "$state_dir" ]] && continue
            local session=$(basename "$state_dir")
            [[ "$first" == "true" ]] && first=false || echo ","
            show_worker_status "$session" true
        done
        echo "]"
    else
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║           RALPH Workers Overview                              ║"
        echo "╠══════════════════════════════════════════════════════════════╣"

        local count=0
        for state_dir in "$STATE_DIR"/*/; do
            [[ ! -d "$state_dir" ]] && continue

            local session=$(basename "$state_dir")
            local state_file="$state_dir/state.json"
            local pid_file="$state_dir/worker.pid"

            [[ ! -f "$state_file" ]] && continue

            local status=$(jq -r '.status // "unknown"' "$state_file" 2>/dev/null)
            local loops=$(jq -r '.loop_count // 0' "$state_file" 2>/dev/null)

            local running_icon="⚪"
            if [[ -f "$pid_file" ]]; then
                local pid=$(cat "$pid_file")
                if kill -0 "$pid" 2>/dev/null; then
                    running_icon="🟢"
                fi
            fi
            [[ "$status" == "completed" ]] && running_icon="✅"
            [[ "$status" == "stopped" || "$status" == "interrupted" ]] && running_icon="🔴"

            local cb_state=$(cb_get_state "$session" 2>/dev/null || echo "?")
            [[ "$cb_state" == "OPEN" ]] && running_icon="🚨"

            printf "║ %s %-15s %-12s loops:%-4s CB:%s\n" "$running_icon" "$session" "$status" "$loops" "$cb_state"
            count=$((count + 1))
        done

        if [[ $count -eq 0 ]]; then
            echo "║ No workers found"
        fi

        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║ Legend: 🟢 Running  ✅ Complete  🔴 Stopped  🚨 Circuit Open  ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
    fi
}

case "${1:-}" in
    --json|-j)
        if [[ -n "$2" ]]; then
            show_worker_status "$2" true
        else
            show_all_workers true
        fi
        ;;
    --help|-h)
        cat << 'EOF'
🔄 ralph-status.sh - RALPH Worker Status

Usage:
  ralph-status.sh                 Show all workers
  ralph-status.sh <session>       Show specific worker
  ralph-status.sh --json          All workers as JSON
  ralph-status.sh --json <sess>   Specific worker as JSON

Examples:
  ralph-status.sh
  ralph-status.sh claude-5
  ralph-status.sh --json | jq '.[] | select(.running)'
EOF
        ;;
    "")
        show_all_workers false
        ;;
    *)
        show_worker_status "$1" false
        ;;
esac
