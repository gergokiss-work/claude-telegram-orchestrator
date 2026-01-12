#!/bin/bash
# Watchdog Control Script
# Manage watchdog from Telegram or CLI
#
# Usage:
#   watchdog-control.sh start [instances...]   - Start watching (optional: specific instances)
#   watchdog-control.sh stop                   - Stop watchdog
#   watchdog-control.sh status                 - Show status
#   watchdog-control.sh add <instance>         - Add instance to watch list
#   watchdog-control.sh remove <instance>      - Remove instance from watch list
#   watchdog-control.sh list                   - List watched instances
#   watchdog-control.sh pause                  - Pause without killing (resume with start)

SCRIPT_DIR="$HOME/.claude/telegram-orchestrator"
CONFIG_FILE="$SCRIPT_DIR/watchdog-config.txt"
WATCHDOG_SCRIPT="$SCRIPT_DIR/night-watchdog.sh"
PID_FILE="$SCRIPT_DIR/watchdog.pid"
PAUSED_FILE="$SCRIPT_DIR/watchdog.paused"

# Ensure config exists
init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'EOF'
# Watchdog Configuration
# One instance per line, lines starting with # are ignored
# Edit this file or use: watchdog-control.sh add/remove <instance>

EOF
    fi
}

get_watched() {
    if [[ -f "$CONFIG_FILE" ]]; then
        grep -v "^#" "$CONFIG_FILE" | grep -v "^$" | tr '\n' ' '
    else
        echo ""
    fi
}

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Also check tmux session
    if tmux has-session -t watchdog 2>/dev/null; then
        return 0
    fi
    return 1
}

cmd_start() {
    if is_running; then
        echo "⚠️ Watchdog already running"
        cmd_status
        return
    fi

    # If specific instances provided, update config
    if [[ $# -gt 0 ]]; then
        init_config
        # Clear and add specified instances
        grep "^#" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null || true
        echo "" >> "${CONFIG_FILE}.tmp"
        for instance in "$@"; do
            echo "$instance" >> "${CONFIG_FILE}.tmp"
        done
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        echo "📝 Watching: $*"
    fi

    # Remove paused flag
    rm -f "$PAUSED_FILE"

    # Start watchdog in tmux
    tmux new-session -d -s watchdog "$WATCHDOG_SCRIPT"

    # Wait and get PID
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

cmd_pause() {
    if ! is_running; then
        echo "⚠️ Watchdog not running"
        return
    fi

    touch "$PAUSED_FILE"
    tmux kill-session -t watchdog 2>/dev/null
    rm -f "$PID_FILE"

    echo "⏸️ Watchdog paused (config preserved, use 'start' to resume)"
}

cmd_status() {
    local status_emoji="🔴"
    local status_text="Stopped"

    if is_running; then
        status_emoji="🟢"
        status_text="Running"
    elif [[ -f "$PAUSED_FILE" ]]; then
        status_emoji="⏸️"
        status_text="Paused"
    fi

    local watched=$(get_watched)
    if [[ -z "$watched" ]]; then
        watched="(none)"
    fi

    echo "$status_emoji Watchdog: $status_text"
    echo "👀 Watching: $watched"

    # Show instance states if running
    if is_running; then
        echo ""
        echo "Instance states:"
        for instance in $watched; do
            if tmux has-session -t "$instance" 2>/dev/null; then
                local state=$(tmux capture-pane -t "$instance" -p 2>/dev/null | tail -10 | grep -oE "thinking|Working|Waiting|idle|bypass" | tail -1 || echo "unknown")
                echo "  • $instance: $state"
            else
                echo "  • $instance: (not running)"
            fi
        done
    fi
}

cmd_add() {
    local instance="$1"
    if [[ -z "$instance" ]]; then
        echo "❌ Usage: watchdog-control.sh add <instance>"
        return 1
    fi

    init_config

    # Check if already in config
    if grep -q "^${instance}$" "$CONFIG_FILE" 2>/dev/null; then
        echo "⚠️ $instance already in watch list"
        return
    fi

    echo "$instance" >> "$CONFIG_FILE"
    echo "✅ Added $instance to watch list"

    # If watchdog running, it will pick up on next cycle
    if is_running; then
        echo "📡 Watchdog will pick up changes on next cycle"
    fi
}

cmd_remove() {
    local instance="$1"
    if [[ -z "$instance" ]]; then
        echo "❌ Usage: watchdog-control.sh remove <instance>"
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "⚠️ No config file"
        return
    fi

    # Remove instance from config
    grep -v "^${instance}$" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo "✅ Removed $instance from watch list"

    if is_running; then
        echo "📡 Watchdog will pick up changes on next cycle"
    fi
}

cmd_list() {
    local watched=$(get_watched)
    if [[ -z "$watched" ]]; then
        echo "📋 Watch list: (empty)"
    else
        echo "📋 Watch list:"
        for instance in $watched; do
            echo "  • $instance"
        done
    fi
}

cmd_help() {
    cat << 'EOF'
🐕 Watchdog Control

Commands:
  start [instances...]  Start watchdog (optionally set which instances)
  stop                  Stop watchdog completely
  pause                 Pause watchdog (preserves config)
  status                Show watchdog status and instance states
  add <instance>        Add instance to watch list
  remove <instance>     Remove instance from watch list
  list                  List watched instances

Examples:
  watchdog-control.sh start claude-3 claude-4   # Watch only these
  watchdog-control.sh add claude-1              # Add to watch list
  watchdog-control.sh remove claude-3           # Stop watching claude-3
  watchdog-control.sh status                    # Check status

From Telegram:
  /watchdog start claude-3 claude-4
  /watchdog stop
  /watchdog add claude-1
  /watchdog status
EOF
}

# Main
init_config

case "${1:-help}" in
    start)   shift; cmd_start "$@" ;;
    stop)    cmd_stop ;;
    pause)   cmd_pause ;;
    status)  cmd_status ;;
    add)     cmd_add "$2" ;;
    remove)  cmd_remove "$2" ;;
    list)    cmd_list ;;
    help|*)  cmd_help ;;
esac
