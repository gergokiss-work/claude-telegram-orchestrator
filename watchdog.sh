#!/bin/bash
# Watchdog v4.0 - Unified watchdog for Claude instances
#
# Usage:
#   watchdog.sh start [instances...]  - Start watching (default: reminder-only mode)
#   watchdog.sh stop                  - Stop watchdog
#   watchdog.sh status                - Show status
#   watchdog.sh add <instance>        - Add instance to watch list
#   watchdog.sh remove <instance>     - Remove from watch list
#   watchdog.sh list                  - List watched instances
#   watchdog.sh daemon                - Run daemon loop (internal)

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SCRIPT_DIR/watchdog-state"
INSTANCES_FILE="$STATE_DIR/instances"
PID_FILE="$STATE_DIR/watchdog.pid"
LOG_FILE="$SCRIPT_DIR/logs/watchdog.log"

# Timing configs
CHECK_INTERVAL=30
FORCE_PUSH_INTERVAL=300      # 5 minutes
REMINDER_INTERVAL=1800       # 30 minutes
REPORT_INTERVAL=1800         # 30 minutes

mkdir -p "$STATE_DIR" "$SCRIPT_DIR/logs"

#
# Utility functions
#

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_telegram() {
    "$SCRIPT_DIR/send-summary.sh" --session "watchdog" "$1" 2>/dev/null
}

get_watched_instances() {
    if [[ -f "$INSTANCES_FILE" ]]; then
        cat "$INSTANCES_FILE" | tr '\n' ' ' | xargs
    fi
}

get_all_claude_instances() {
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^claude-" | tr '\n' ' '
}

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    tmux has-session -t watchdog 2>/dev/null && return 0
    return 1
}

#
# State detection
#

detect_state() {
    local session=$1
    local output=$(tmux capture-pane -t "$session" -p 2>/dev/null)

    [[ -z "$output" ]] && echo "dead" && return

    local last_lines=$(echo "$output" | tail -20)

    # Low context
    if echo "$last_lines" | grep -qE "Context left.*[0-9]%"; then
        local ctx=$(echo "$last_lines" | grep -oE "[0-9]+%" | head -1 | tr -d '%')
        [[ -n "$ctx" && "$ctx" -lt 15 ]] && echo "low_context" && return
    fi

    # Stuck states
    echo "$last_lines" | grep -qE "Would you like to proceed|❯.*1\.|❯.*2\.|Y/n|\[y/N\]" && echo "approval_prompt" && return
    echo "$last_lines" | grep -qE "plan mode on" && echo "plan_mode" && return
    echo "$last_lines" | grep -qE "^quote>|dquote>" && echo "quote_stuck" && return
    echo "$last_lines" | grep -qE "↵ send|Press up to edit" && echo "input_pending" && return

    # Working states
    echo "$last_lines" | grep -qE "thinking|Waiting|Reading|Writing|Finagling|Unravelling|Pondering|esc to interrupt" && echo "working" && return
    echo "$last_lines" | grep -qE "background task" && echo "working" && return

    # Idle
    echo "$last_lines" | grep -qE "bypass permissions" && echo "idle" && return

    echo "unknown"
}

fix_stuck_state() {
    local session=$1
    local state=$2

    log "[$session] Fixing: $state"

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
        "low_context"|"dead")
            log "[$session] Restarting session"
            tmux kill-session -t "$session" 2>/dev/null
            sleep 1
            tmux new-session -d -s "$session" -c "$HOME" "claude --dangerously-skip-permissions"
            sleep 3
            force_push "$session" "Session restarted. Check your working directory and continue."
            send_telegram "🔄 <b>$session restarted</b>: $state"
            ;;
    esac
}

#
# Actions
#

force_push() {
    local session=$1
    local custom_msg=$2

    local recent=$(tmux capture-pane -t "$session" -p -S -30 2>/dev/null | grep -E "^⏺|✓|✗|☐|☒" | tail -5)

    local msg="${custom_msg:-Keep working!}

Recent activity:
$recent

REMINDERS:
1. Continue your current task
2. Send Telegram update when done:
   ~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') \"Update\"
3. Write TTS summary:
   ~/.claude/scripts/tts-write.sh \"Summary\"

Keep going!"

    tmux send-keys -t "$session" C-u 2>/dev/null
    sleep 0.2
    "$SCRIPT_DIR/inject-prompt.sh" "$session" "$msg" 2>/dev/null

    date +%s > "$STATE_DIR/${session}_last_push"
    log "[$session] Force pushed"
}

inject_reminder() {
    local session=$1

    local state=$(detect_state "$session")
    [[ "$state" = "working" ]] && return

    local reminder="📢 Reminder: When you complete tasks:

1. Send Telegram: ~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') \"Update\"
2. Write TTS: ~/.claude/scripts/tts-write.sh \"Summary\""

    tmux send-keys -t "$session" C-u 2>/dev/null
    sleep 0.2
    "$SCRIPT_DIR/inject-prompt.sh" "$session" "$reminder" 2>/dev/null
    log "[$session] Reminder sent"
}

#
# Commands
#

cmd_start() {
    if is_running; then
        echo "⚠️ Watchdog already running"
        cmd_status
        return
    fi

    # Save instances to watch
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$@" > "$INSTANCES_FILE"
        echo "📝 Watching: $*"
    else
        > "$INSTANCES_FILE"  # Empty = reminder-only mode
        echo "📝 Reminder-only mode (no instances to force-push)"
    fi

    # Start daemon in tmux
    tmux new-session -d -s watchdog "$SCRIPT_DIR/watchdog.sh daemon"
    sleep 2

    local pid=$(tmux list-panes -t watchdog -F "#{pane_pid}" 2>/dev/null | head -1)
    echo "$pid" > "$PID_FILE"

    echo "✅ Watchdog started"
    cmd_status
}

cmd_stop() {
    if ! is_running; then
        echo "⚠️ Watchdog not running"
        return
    fi

    tmux kill-session -t watchdog 2>/dev/null
    rm -f "$PID_FILE"
    echo "🛑 Watchdog stopped"
}

cmd_status() {
    local status_emoji="🔴"
    local status_text="Stopped"

    if is_running; then
        status_emoji="🟢"
        status_text="Running"
    fi

    local watched=$(get_watched_instances)
    [[ -z "$watched" ]] && watched="(none - reminder only)"

    echo "$status_emoji Watchdog: $status_text"
    echo "👀 Watching: $watched"

    if is_running && [[ -n "$(get_watched_instances)" ]]; then
        echo ""
        echo "Instance states:"
        for instance in $(get_watched_instances); do
            if tmux has-session -t "$instance" 2>/dev/null; then
                local state=$(detect_state "$instance")
                echo "  • $instance: $state"
            else
                echo "  • $instance: (not running)"
            fi
        done
    fi
}

cmd_add() {
    local instance=$1
    [[ -z "$instance" ]] && echo "❌ Usage: watchdog.sh add <instance>" && return 1

    if grep -q "^${instance}$" "$INSTANCES_FILE" 2>/dev/null; then
        echo "⚠️ $instance already in watch list"
        return
    fi

    echo "$instance" >> "$INSTANCES_FILE"
    echo "✅ Added $instance"
    is_running && echo "📡 Will take effect on next cycle"
}

cmd_remove() {
    local instance=$1
    [[ -z "$instance" ]] && echo "❌ Usage: watchdog.sh remove <instance>" && return 1

    if [[ -f "$INSTANCES_FILE" ]]; then
        grep -v "^${instance}$" "$INSTANCES_FILE" > "${INSTANCES_FILE}.tmp"
        mv "${INSTANCES_FILE}.tmp" "$INSTANCES_FILE"
    fi

    echo "✅ Removed $instance"
    is_running && echo "📡 Will take effect on next cycle"
}

cmd_list() {
    local watched=$(get_watched_instances)
    if [[ -z "$watched" ]]; then
        echo "📋 Watch list: (empty - reminder only mode)"
    else
        echo "📋 Watch list:"
        for instance in $watched; do
            echo "  • $instance"
        done
    fi
}

cmd_daemon() {
    log "========================================="
    log "Watchdog v4.0 started"
    log "========================================="

    local instances=$(get_watched_instances)
    log "Watching: ${instances:-none (reminder only)}"

    # Initialize push times
    for session in $instances; do
        echo "0" > "$STATE_DIR/${session}_last_push"
    done

    send_telegram "🐕 <b>Watchdog v4.0 Started</b>

<b>Watching:</b> ${instances:-none (reminder only)}

<b>Actions:</b>
• Force push watched instances every 5 min
• TTS/Telegram reminder to ALL every 30 min
• Auto-fix stuck states"

    local last_report=$(date +%s)
    local last_reminder=$(date +%s)

    while true; do
        local instances=$(get_watched_instances)

        # Check watched instances
        for session in $instances; do
            if ! tmux has-session -t "$session" 2>/dev/null; then
                log "[$session] Not running - skipping"
                continue
            fi

            local state=$(detect_state "$session")
            local last_push=$(cat "$STATE_DIR/${session}_last_push" 2>/dev/null || echo "0")
            local time_since_push=$(($(date +%s) - last_push))

            log "[$session] State: $state (${time_since_push}s since push)"

            # Fix stuck states
            case $state in
                "approval_prompt"|"plan_mode"|"quote_stuck"|"input_pending"|"low_context"|"dead")
                    fix_stuck_state "$session" "$state"
                    sleep 1
                    ;;
            esac

            # Force push every 5 min
            if [[ $time_since_push -ge $FORCE_PUSH_INTERVAL ]]; then
                force_push "$session"
            fi

            sleep 2
        done

        local current_time=$(date +%s)

        # Status report every 30 min
        if [[ $((current_time - last_report)) -ge $REPORT_INTERVAL ]]; then
            local report="🐕 <b>Watchdog Status</b>\n\n"
            for session in $instances; do
                local state=$(detect_state "$session")
                report+="<b>$session:</b> $state\n"
            done
            send_telegram "$report"
            last_report=$current_time
        fi

        # Reminder to ALL instances every 30 min
        if [[ $((current_time - last_reminder)) -ge $REMINDER_INTERVAL ]]; then
            log "Sending reminders to all instances"
            for session in $(get_all_claude_instances); do
                inject_reminder "$session"
                sleep 1
            done
            last_reminder=$current_time
        fi

        sleep $CHECK_INTERVAL
    done
}

cmd_help() {
    cat << 'EOF'
🐕 Watchdog v4.0

Usage: watchdog.sh <command> [args]

Commands:
  start [instances...]  Start watchdog (empty = reminder-only mode)
  stop                  Stop watchdog
  status                Show status
  add <instance>        Add instance to watch list
  remove <instance>     Remove from watch list
  list                  List watched instances

Examples:
  watchdog.sh start claude-1 claude-3   # Watch specific instances
  watchdog.sh start                      # Reminder-only mode
  watchdog.sh add claude-2              # Add to watch list
  watchdog.sh status                    # Check status
EOF
}

#
# Main
#

case "${1:-help}" in
    start)   shift; cmd_start "$@" ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    add)     cmd_add "$2" ;;
    remove)  cmd_remove "$2" ;;
    list)    cmd_list ;;
    daemon)  cmd_daemon ;;
    help|*)  cmd_help ;;
esac
