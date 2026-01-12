#!/bin/bash
# AGGRESSIVE Watchdog v3.0
# Forces claude instances to keep working - NO EXCUSES
# Compatible with macOS bash (no associative arrays)

set -o pipefail

SCRIPT_DIR="$HOME/.claude/telegram-orchestrator"
CONFIG_FILE="$SCRIPT_DIR/watchdog-config.txt"
LOG_FILE="$SCRIPT_DIR/logs/watchdog-$(date +%Y%m%d).log"
STATE_DIR="$SCRIPT_DIR/watchdog-state"

# Timing configs
CHECK_INTERVAL=30           # Check every 30 seconds
FORCE_PUSH_INTERVAL=300     # Force push every 5 minutes NO MATTER WHAT
REPORT_INTERVAL=1800        # Report every 30 minutes

mkdir -p "$SCRIPT_DIR/logs" "$STATE_DIR"

# Default instances to watch
DEFAULT_INSTANCES="claude-1 claude-3"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_telegram() {
    "$SCRIPT_DIR/send-summary.sh" --session "watchdog" "$1" 2>/dev/null
    log "TG: ${1:0:60}..."
}

get_instances() {
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE" | grep -v "^#" | grep -v "^$" | tr '\n' ' '
    else
        echo "$DEFAULT_INSTANCES"
    fi
}

get_last_push() {
    local session=$1
    local file="$STATE_DIR/${session}_last_push"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "0"
    fi
}

set_last_push() {
    local session=$1
    date +%s > "$STATE_DIR/${session}_last_push"
}

detect_state() {
    local session=$1
    local output=$(tmux capture-pane -t "$session" -p 2>/dev/null)

    if [ -z "$output" ]; then
        echo "dead"
        return
    fi

    local last_lines=$(echo "$output" | tail -20)

    # Check context remaining
    if echo "$last_lines" | grep -qE "Context left.*[0-9]%"; then
        local ctx=$(echo "$last_lines" | grep -oE "[0-9]+%" | head -1 | tr -d '%')
        if [ -n "$ctx" ] && [ "$ctx" -lt 15 ]; then
            echo "low_context"
            return
        fi
    fi

    # STUCK states
    if echo "$last_lines" | grep -qE "Would you like to proceed|❯.*1\.|❯.*2\.|Y/n|\[y/N\]"; then
        echo "approval_prompt"
        return
    fi

    if echo "$last_lines" | grep -qE "plan mode on"; then
        echo "plan_mode"
        return
    fi

    if echo "$last_lines" | grep -qE "^quote>|dquote>"; then
        echo "quote_stuck"
        return
    fi

    if echo "$last_lines" | grep -qE "↵ send|Press up to edit"; then
        echo "input_pending"
        return
    fi

    # WORKING states
    if echo "$last_lines" | grep -qE "thinking|Waiting|Reading|Writing|Finagling|Unravelling|Pondering|esc to interrupt"; then
        echo "working"
        return
    fi

    if echo "$last_lines" | grep -qE "background task"; then
        echo "working"
        return
    fi

    # IDLE state
    if echo "$last_lines" | grep -qE "bypass permissions"; then
        echo "idle"
        return
    fi

    echo "unknown"
}

fix_stuck_state() {
    local session=$1
    local state=$2

    log "[$session] Fixing stuck state: $state"

    case $state in
        "approval_prompt")
            tmux send-keys -t "$session" "1" Enter
            sleep 0.5
            tmux send-keys -t "$session" Enter
            ;;
        "plan_mode")
            tmux send-keys -t "$session" Escape
            sleep 0.3
            tmux send-keys -t "$session" Enter
            ;;
        "quote_stuck")
            tmux send-keys -t "$session" C-c C-u Enter
            ;;
        "input_pending")
            tmux send-keys -t "$session" Enter Enter
            ;;
        "low_context")
            log "[$session] LOW CONTEXT - Restarting session"
            restart_session "$session"
            send_telegram "🔄 <b>$session restarted</b>: Context was too low"
            ;;
        "dead")
            log "[$session] DEAD - Restarting session"
            restart_session "$session"
            send_telegram "🚨 <b>$session restarted</b>: Session was dead"
            ;;
    esac
}

restart_session() {
    local session=$1
    tmux kill-session -t "$session" 2>/dev/null
    sleep 1
    tmux new-session -d -s "$session" -c "$HOME/work/gergo/robo-snoo" "claude --dangerously-skip-permissions"
    sleep 3
    force_push "$session" "Session was restarted. Orient yourself in ~/work/gergo/robo-snoo. Check PROGRESS.md and TODO.md for context. Start working!"
}

force_push() {
    local session=$1
    local custom_msg=$2

    local recent=$(tmux capture-pane -t "$session" -p -S -30 2>/dev/null | grep -E "^⏺|✓|✗|☐|☒" | tail -5)

    local msg="${custom_msg:-Keep working on robo-snoo!}

TEAM SETUP:
- claude-1: Implementer (builds features)
- claude-3: Reviewer (reviews and pushes claude-1)

Recent:
$recent

DO NOW:
1. Pick next task from TODO.md or PROGRESS.md
2. If reviewing: tmux capture-pane -t claude-1 -p | tail -20
3. Send Telegram update after completing something:
   ~/.claude/telegram-orchestrator/send-summary.sh --session $session \"Update\"

NO IDLING! 🏭"

    tmux send-keys -t "$session" C-u 2>/dev/null
    sleep 0.2
    "$SCRIPT_DIR/inject-prompt.sh" "$session" "$msg" 2>/dev/null

    set_last_push "$session"
    log "[$session] Force pushed"
}

check_and_handle() {
    local session=$1
    local current_time=$(date +%s)
    local last_push=$(get_last_push "$session")
    local time_since_push=$((current_time - last_push))

    # Check if session exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "[$session] Session doesn't exist - creating"
        tmux new-session -d -s "$session" -c "$HOME/work/gergo/robo-snoo" "claude --dangerously-skip-permissions"
        sleep 3
        force_push "$session" "New session. Start working on robo-snoo!"
        return
    fi

    local state=$(detect_state "$session")
    log "[$session] State: $state (${time_since_push}s since push)"

    # Fix stuck states IMMEDIATELY
    case $state in
        "approval_prompt"|"plan_mode"|"quote_stuck"|"input_pending"|"low_context"|"dead")
            fix_stuck_state "$session" "$state"
            sleep 1
            ;;
    esac

    # FORCE PUSH every 5 minutes NO MATTER WHAT
    if [ $time_since_push -ge $FORCE_PUSH_INTERVAL ]; then
        log "[$session] 5-min force push"
        force_push "$session"
    fi
}

send_status_report() {
    local instances=$(get_instances)
    local report="🐕 <b>Watchdog v3.0 Status</b>

"
    for session in $instances; do
        local state=$(detect_state "$session")
        local last_push=$(get_last_push "$session")
        local ago=$(($(date +%s) - last_push))
        report+="<b>$session:</b> $state (${ago}s ago)
"
    done

    report+="
⚡ Force push every 5min"
    send_telegram "$report"
}

# Initialize
log "========================================="
log "AGGRESSIVE WATCHDOG v3.0 STARTED"
log "Force push: every ${FORCE_PUSH_INTERVAL}s (5 min)"
log "========================================="

INSTANCES=$(get_instances)
log "Watching: $INSTANCES"

# Initialize push times to 0 (will trigger immediate push)
for session in $INSTANCES; do
    echo "0" > "$STATE_DIR/${session}_last_push"
done

send_telegram "🐕 <b>Watchdog v3.0 Started!</b>

<b>Watching:</b> $INSTANCES

<b>Features:</b>
• ⚡ Force push every 5 min NO MATTER WHAT
• 🔧 Auto-fix stuck states
• 🔄 Auto-restart dead sessions
• 📊 Reports every 30 min

<b>Config:</b> Edit watchdog-config.txt

🏭 Factory WILL keep running!"

LAST_REPORT=$(date +%s)

# Main loop
while true; do
    INSTANCES=$(get_instances)

    for session in $INSTANCES; do
        check_and_handle "$session"
        sleep 2
    done

    # Periodic report
    current_time=$(date +%s)
    time_since_report=$((current_time - LAST_REPORT))
    if [ $time_since_report -ge $REPORT_INTERVAL ]; then
        send_status_report
        LAST_REPORT=$current_time
    fi

    sleep $CHECK_INTERVAL
done
