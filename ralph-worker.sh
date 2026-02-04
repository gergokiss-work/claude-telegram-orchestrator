#!/bin/bash
# RALPH Worker - Sophisticated Autonomous Loop for Claude Sessions
#
# Usage:
#   ralph-worker.sh <session> [--task-file <file>] [--max-loops N] [--foreground]
#   ralph-worker.sh <session> --status
#   ralph-worker.sh <session> --stop
#
# This script runs a sophisticated RALPH-style loop on a Claude session,
# integrating with the Telegram orchestrator ecosystem.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
STATE_DIR="$SCRIPT_DIR/worker-state"
HANDOFFS_DIR="$HOME/.claude/handoffs"

# Source libraries
source "$LIB_DIR/circuit_breaker.sh"
source "$LIB_DIR/response_analyzer.sh"
source "$LIB_DIR/rate_limiter.sh"
source "$LIB_DIR/exit_detector.sh"

# Configuration
MAX_LOOPS=${RALPH_MAX_LOOPS:-100}
LOOP_TIMEOUT=${RALPH_LOOP_TIMEOUT:-900}  # 15 minutes per loop
RESPONSE_WAIT_INTERVAL=5                  # Seconds between response checks
RESPONSE_WAIT_MAX=300                     # Max seconds to wait for response

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#
# State Management
#

_worker_state_file() {
    local session=$1
    echo "$STATE_DIR/$session/state.json"
}

_worker_pid_file() {
    local session=$1
    echo "$STATE_DIR/$session/worker.pid"
}

_worker_log_file() {
    local session=$1
    echo "$STATE_DIR/$session/worker.log"
}

log() {
    local level=$1
    local msg=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

init_worker_state() {
    local session=$1
    local task_file=$2

    mkdir -p "$STATE_DIR/$session"

    local state_file=$(_worker_state_file "$session")

    cat > "$state_file" << EOF
{
    "session": "$session",
    "task_file": "$task_file",
    "status": "initializing",
    "loop_count": 0,
    "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "last_loop_at": null,
    "total_files_modified": 0,
    "exit_reason": null
}
EOF
}

update_worker_state() {
    local session=$1
    local field=$2
    local value=$3

    local state_file=$(_worker_state_file "$session")

    if [[ -f "$state_file" ]]; then
        local tmp=$(mktemp)
        jq ".$field = $value" "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    fi
}

get_worker_state() {
    local session=$1
    local state_file=$(_worker_state_file "$session")

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo '{"status": "not_running"}'
    fi
}

#
# Loop Context Building
#

build_loop_context() {
    local session=$1
    local loop_number=$2
    local task_file=$3

    local cb_state=$(cb_get_state "$session")
    local rate_remaining=$(rl_get_remaining "$session")
    local task_progress=""

    # Get task progress
    if [[ -f "$task_file" ]]; then
        local total=$(grep -cE "^\s*- \[[ x]\]" "$task_file" 2>/dev/null || echo "0")
        local done=$(grep -cE "^\s*- \[x\]" "$task_file" 2>/dev/null || echo "0")
        task_progress="$done/$total checkboxes complete"
    fi

    # Get previous loop summary (from response analysis)
    local prev_summary=""
    local response_file="$STATE_DIR/$session/response.json"
    if [[ -f "$response_file" ]]; then
        prev_summary=$(jq -r '.ralph_status.recommendation // "Continue working"' "$response_file" 2>/dev/null)
    fi

    cat << EOF
---
## 🔄 RALPH Loop Context (Loop #$loop_number)

**Session:** $session
**Task Progress:** $task_progress
**Circuit Breaker:** $cb_state
**Rate Limit:** $rate_remaining calls remaining this hour

### Previous Loop
$prev_summary

### Your Task
Read your task file and continue working:
\`\`\`bash
cat $task_file
\`\`\`

### Important Reminders
1. Check boxes [x] in the task file as you complete items
2. Update RALPH_STATUS block at the end of your response
3. Set EXIT_SIGNAL: true ONLY when ALL work is complete
4. Send Telegram summary when completing major milestones:
   \`~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') "msg"\`

### Status Block (Required)
Include this at the end of your response:
\`\`\`
RALPH_STATUS:
STATUS: IN_PROGRESS | COMPLETE
EXIT_SIGNAL: false | true
WORK_TYPE: feature | bugfix | test | docs | refactor
FILES_MODIFIED: <number>
TASKS_REMAINING: <number>
RECOMMENDATION: <what to do next loop>
\`\`\`
---

EOF
}

#
# Response Waiting
#

wait_for_response() {
    local session=$1
    local waited=0

    log "INFO" "Waiting for Claude to finish..."

    while [[ $waited -lt $RESPONSE_WAIT_MAX ]]; do
        sleep $RESPONSE_WAIT_INTERVAL
        waited=$((waited + RESPONSE_WAIT_INTERVAL))

        # Capture pane content
        local output=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -20)

        # Check if Claude is done (shows input prompt or idle indicators)
        if echo "$output" | grep -qE "(↵ send|Press up to edit|bypass permissions)"; then
            log "INFO" "Response complete (waited ${waited}s)"
            return 0
        fi

        # Check if still thinking
        if echo "$output" | grep -qE "(thinking|esc to interrupt|Pondering|Reasoning)"; then
            log "DEBUG" "Still thinking... (${waited}s)"
            continue
        fi

        # Progress indicator
        if [[ $((waited % 30)) -eq 0 ]]; then
            log "INFO" "Still waiting... (${waited}s)"
        fi
    done

    log "WARN" "Response wait timeout after ${RESPONSE_WAIT_MAX}s"
    return 1
}

#
# Single Loop Iteration
#

run_loop_iteration() {
    local session=$1
    local loop_number=$2
    local task_file=$3

    log "INFO" "========== Loop #$loop_number starting =========="

    # Check rate limit
    if ! rl_can_call "$session"; then
        log "WARN" "Rate limit reached, waiting for reset..."
        rl_wait_for_reset "$session"
    fi

    # Build and inject context
    local context=$(build_loop_context "$session" "$loop_number" "$task_file")

    log "INFO" "Injecting loop context..."
    "$SCRIPT_DIR/inject-prompt.sh" "$session" "$context" 2>/dev/null

    # Record the call
    rl_record_call "$session"

    # Wait for response
    if ! wait_for_response "$session"; then
        log "WARN" "Response timeout - treating as no progress"
    fi

    # Capture full output
    local output=$(tmux capture-pane -t "$session" -p -S -500 2>/dev/null)

    # Analyze response
    log "INFO" "Analyzing response..."
    local analysis=$(ra_analyze "$session" "$output" "$loop_number")

    # Parse analysis results: files|has_errors|error_hash|completion|output_len|exit_signal
    IFS='|' read -r files_changed has_errors error_hash completion_count output_length exit_signal <<< "$analysis"

    log "INFO" "Analysis: files=$files_changed, errors=$has_errors, completion=$completion_count, exit=$exit_signal"

    # Detect test-only and done signals
    local is_test_only=$(ra_detect_test_only "$output")
    local has_done_signal="false"
    if echo "$output" | grep -qiE "all done|finished|complete"; then
        has_done_signal="true"
    fi

    # Record for exit detector
    ed_record_signals "$session" "$loop_number" "$is_test_only" "$has_done_signal" "$completion_count"

    # Record for circuit breaker
    cb_record_result "$session" "$files_changed" "$has_errors" "$output_length" "$error_hash" "$completion_count"

    # Update worker state
    update_worker_state "$session" "loop_count" "$loop_number"
    update_worker_state "$session" "last_loop_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

    local total_files=$(jq -r '.total_files_modified // 0' "$(_worker_state_file "$session")")
    total_files=$((total_files + files_changed))
    update_worker_state "$session" "total_files_modified" "$total_files"

    # Check exit conditions
    local exit_reason=$(ed_check "$session" "$exit_signal")
    if [[ -n "$exit_reason" ]]; then
        log "INFO" "Exit condition met: $exit_reason"
        return 1  # Signal to exit
    fi

    # Check circuit breaker
    if cb_should_halt "$session"; then
        log "WARN" "Circuit breaker OPEN - halting"
        return 2  # Signal circuit breaker halt
    fi

    log "INFO" "========== Loop #$loop_number complete =========="
    return 0
}

#
# Main Loop
#

run_worker_loop() {
    local session=$1
    local task_file=$2
    local max_loops=$3

    LOG_FILE=$(_worker_log_file "$session")

    log "INFO" "╔══════════════════════════════════════════════════╗"
    log "INFO" "║     RALPH Worker Starting                         ║"
    log "INFO" "╠══════════════════════════════════════════════════╣"
    log "INFO" "║ Session:    $session"
    log "INFO" "║ Task File:  $task_file"
    log "INFO" "║ Max Loops:  $max_loops"
    log "INFO" "╚══════════════════════════════════════════════════╝"

    # Initialize state
    init_worker_state "$session" "$task_file"
    cb_init "$session"
    rl_init "$session"
    ed_init "$session"

    # Save PID
    echo $$ > "$(_worker_pid_file "$session")"

    # Update status
    update_worker_state "$session" "status" '"running"'

    # Notify start
    "$SCRIPT_DIR/send-summary.sh" --session "$session" "🔄 <b>RALPH Worker Started</b>

<b>Session:</b> $session
<b>Task:</b> $(head -1 "$task_file" | sed 's/^# Task: //')
<b>Max Loops:</b> $max_loops

Worker running autonomously." 2>/dev/null

    # Main loop
    local loop=1
    local exit_reason=""

    while [[ $loop -le $max_loops ]]; do
        # Check if session still exists
        if ! tmux has-session -t "$session" 2>/dev/null; then
            log "ERROR" "Session $session no longer exists"
            exit_reason="session_died"
            break
        fi

        # Run iteration
        run_loop_iteration "$session" "$loop" "$task_file"
        local result=$?

        if [[ $result -eq 1 ]]; then
            exit_reason=$(ed_check "$session" "$(ra_get_exit_signal "$session")")
            break
        elif [[ $result -eq 2 ]]; then
            exit_reason="circuit_breaker_open"
            break
        fi

        loop=$((loop + 1))

        # Small delay between loops
        sleep 2
    done

    # Check if max loops reached
    [[ $loop -gt $max_loops ]] && exit_reason="max_loops_reached"

    # Update final state
    update_worker_state "$session" "status" '"completed"'
    update_worker_state "$session" "exit_reason" "\"$exit_reason\""

    # Clean up PID file
    rm -f "$(_worker_pid_file "$session")"

    log "INFO" "╔══════════════════════════════════════════════════╗"
    log "INFO" "║     RALPH Worker Finished                         ║"
    log "INFO" "╠══════════════════════════════════════════════════╣"
    log "INFO" "║ Loops Run:    $((loop - 1))"
    log "INFO" "║ Exit Reason:  $exit_reason"
    log "INFO" "╚══════════════════════════════════════════════════╝"

    # Final notification
    local reason_desc=$(ed_get_reason_description "$exit_reason")
    "$SCRIPT_DIR/send-summary.sh" --session "$session" "✅ <b>RALPH Worker Complete</b>

<b>Session:</b> $session
<b>Loops Run:</b> $((loop - 1))
<b>Exit Reason:</b> $reason_desc

Check task file for results." 2>/dev/null

    # TTS
    ~/.claude/scripts/tts-write.sh "Ralph worker finished after $((loop - 1)) loops. $exit_reason" 2>/dev/null
}

#
# Commands
#

cmd_start() {
    local session=$1
    shift

    local task_file=""
    local max_loops=$MAX_LOOPS
    local foreground=false

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-file|-t)
                task_file="$2"
                shift 2
                ;;
            --max-loops|-m)
                max_loops="$2"
                shift 2
                ;;
            --foreground|-f)
                foreground=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Default task file
    [[ -z "$task_file" ]] && task_file="$HANDOFFS_DIR/${session}-task.md"

    # Validate
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "❌ Session $session does not exist"
        exit 1
    fi

    if [[ ! -f "$task_file" ]]; then
        echo "❌ Task file not found: $task_file"
        echo "Create one with: ralph-task.sh $session \"Task description\""
        exit 1
    fi

    # Check if already running
    local pid_file=$(_worker_pid_file "$session")
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "⚠️ Worker already running for $session (PID: $pid)"
            exit 1
        fi
        rm -f "$pid_file"
    fi

    echo "🚀 Starting RALPH Worker for $session"
    echo "   Task: $task_file"
    echo "   Max loops: $max_loops"

    if [[ "$foreground" == "true" ]]; then
        run_worker_loop "$session" "$task_file" "$max_loops"
    else
        # Run in background
        nohup "$0" "$session" --task-file "$task_file" --max-loops "$max_loops" --foreground \
            >> "$(_worker_log_file "$session")" 2>&1 &
        local bg_pid=$!
        echo "$bg_pid" > "$(_worker_pid_file "$session")"
        echo "   Background PID: $bg_pid"
        echo ""
        echo "Monitor with: tail -f $(_worker_log_file "$session")"
        echo "Status with:  ralph-worker.sh $session --status"
        echo "Stop with:    ralph-worker.sh $session --stop"
    fi
}

cmd_status() {
    local session=$1

    local state=$(get_worker_state "$session")
    local status=$(echo "$state" | jq -r '.status // "not_running"')

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         RALPH Worker Status: $session"
    echo "╠══════════════════════════════════════════════════════════╣"

    if [[ "$status" == "not_running" ]]; then
        echo "║ Status: Not running"
        echo "╚══════════════════════════════════════════════════════════╝"
        return
    fi

    local loops=$(echo "$state" | jq -r '.loop_count // 0')
    local started=$(echo "$state" | jq -r '.started_at // "unknown"')
    local last_loop=$(echo "$state" | jq -r '.last_loop_at // "never"')
    local files=$(echo "$state" | jq -r '.total_files_modified // 0')
    local task=$(echo "$state" | jq -r '.task_file // "unknown"')

    # Check if actually running
    local pid_file=$(_worker_pid_file "$session")
    local running="No"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            running="Yes (PID: $pid)"
        fi
    fi

    echo "║ Status:       $status"
    echo "║ Running:      $running"
    echo "║ Loops:        $loops"
    echo "║ Files Mod:    $files"
    echo "║ Started:      $started"
    echo "║ Last Loop:    $last_loop"
    echo "║ Task File:    $task"
    echo "╠══════════════════════════════════════════════════════════╣"

    # Show component statuses
    cb_show_status "$session" 2>/dev/null | sed 's/^/║ /'
    echo "╠══════════════════════════════════════════════════════════╣"
    rl_show_status "$session" 2>/dev/null | sed 's/^/║ /'
    echo "╠══════════════════════════════════════════════════════════╣"
    ed_show_status "$session" 2>/dev/null | sed 's/^/║ /'

    echo "╚══════════════════════════════════════════════════════════╝"
}

cmd_stop() {
    local session=$1

    local pid_file=$(_worker_pid_file "$session")

    if [[ ! -f "$pid_file" ]]; then
        echo "⚠️ No worker running for $session"
        return 1
    fi

    local pid=$(cat "$pid_file")

    if kill -0 "$pid" 2>/dev/null; then
        echo "🛑 Stopping worker (PID: $pid)..."
        kill "$pid"
        sleep 2

        if kill -0 "$pid" 2>/dev/null; then
            echo "   Force killing..."
            kill -9 "$pid"
        fi

        rm -f "$pid_file"
        update_worker_state "$session" "status" '"stopped"'
        echo "✅ Worker stopped"
    else
        echo "⚠️ Worker not running (stale PID file)"
        rm -f "$pid_file"
    fi
}

cmd_help() {
    cat << 'EOF'
🔄 RALPH Worker - Sophisticated Autonomous Loop

Usage:
  ralph-worker.sh <session> [options]           Start worker
  ralph-worker.sh <session> --status            Show status
  ralph-worker.sh <session> --stop              Stop worker

Options:
  --task-file, -t <file>    Task file (default: ~/.claude/handoffs/<session>-task.md)
  --max-loops, -m <N>       Maximum loops (default: 100)
  --foreground, -f          Run in foreground (default: background)

Features:
  • 3-state circuit breaker (CLOSED → HALF_OPEN → OPEN)
  • Rate limiting (100 calls/hour)
  • Multi-condition exit detection
  • Response analysis with RALPH_STATUS parsing
  • Automatic recovery in HALF_OPEN state
  • Integration with Telegram/TTS notifications

Examples:
  ralph-worker.sh claude-5                      # Start with default task file
  ralph-worker.sh claude-5 -m 50 -f             # 50 loops, foreground
  ralph-worker.sh claude-5 --status             # Check status
  ralph-worker.sh claude-5 --stop               # Stop worker

Workflow:
  1. Create task: ralph-task.sh claude-5 "Build feature X"
  2. Start worker: ralph-worker.sh claude-5
  3. Monitor: tail -f ~/.claude/telegram-orchestrator/worker-state/claude-5/worker.log
  4. Worker runs autonomously until exit condition or max loops
EOF
}

#
# Signal Handlers
#

cleanup() {
    local session=${WORKER_SESSION:-"unknown"}
    log "WARN" "Received interrupt signal, cleaning up..."

    update_worker_state "$session" "status" '"interrupted"'
    rm -f "$(_worker_pid_file "$session")"

    "$SCRIPT_DIR/send-summary.sh" --session "$session" "⚠️ <b>RALPH Worker Interrupted</b>

<b>Session:</b> $session
Worker was interrupted. Task file preserved." 2>/dev/null

    exit 130
}

trap cleanup SIGINT SIGTERM

#
# Main
#

case "${1:-}" in
    --help|-h|"")
        cmd_help
        ;;
    *)
        session=$1
        shift

        case "${1:-}" in
            --status|-s)
                cmd_status "$session"
                ;;
            --stop)
                cmd_stop "$session"
                ;;
            *)
                WORKER_SESSION="$session"
                cmd_start "$session" "$@"
                ;;
        esac
        ;;
esac
