#!/bin/bash
# TTS Toggle Script v2.0
# Usage: tts-toggle.sh [on|off|status]
# If no argument, toggles current state

TTS_DIR="$HOME/.claude/tts"
ENABLED_FILE="$TTS_DIR/enabled"
QUEUE_DIR="$TTS_DIR/queue"
DAEMON_PID_FILE="$TTS_DIR/daemon.pid"

mkdir -p "$TTS_DIR" "$QUEUE_DIR"

is_enabled() {
    [[ -f "$ENABLED_FILE" ]]
}

start_daemon() {
    # Kill any existing daemon
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local old_pid=$(cat "$DAEMON_PID_FILE")
        kill "$old_pid" 2>/dev/null
        rm -f "$DAEMON_PID_FILE"
    fi

    # Start new daemon in background
    nohup bash -c '
        while true; do
            if [[ -f "'"$ENABLED_FILE"'" ]]; then
                "'"$HOME"'/.claude/scripts/tts-reader.sh" 2>/dev/null
            fi
            sleep 2
        done
    ' > /dev/null 2>&1 &

    echo $! > "$DAEMON_PID_FILE"
}

stop_daemon() {
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local pid=$(cat "$DAEMON_PID_FILE")
        kill "$pid" 2>/dev/null
        rm -f "$DAEMON_PID_FILE"
    fi

    # Also kill any running say/afplay
    pkill -f "say -v" 2>/dev/null
    pkill -f "afplay" 2>/dev/null
}

enable_tts() {
    touch "$ENABLED_FILE"
    start_daemon
    echo "🔊 TTS ENABLED (daemon started)"
}

disable_tts() {
    rm -f "$ENABLED_FILE"
    stop_daemon
    # Clear queue when disabled
    rm -f "$QUEUE_DIR"/*.txt 2>/dev/null
    echo "🔇 TTS DISABLED (queue cleared)"
}

get_status() {
    local queue_count=$(ls -1 "$QUEUE_DIR"/*.txt 2>/dev/null | wc -l | tr -d ' ')
    local daemon_status="not running"

    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local pid=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            daemon_status="running (PID: $pid)"
        fi
    fi

    if is_enabled; then
        echo "🔊 TTS: ENABLED"
    else
        echo "🔇 TTS: DISABLED"
    fi
    echo "Daemon: $daemon_status"
    echo "Queue: $queue_count files"
}

case "${1:-toggle}" in
    on|enable)
        enable_tts
        ;;
    off|disable)
        disable_tts
        ;;
    status)
        get_status
        ;;
    toggle)
        if is_enabled; then
            disable_tts
        else
            enable_tts
        fi
        ;;
    *)
        echo "Usage: tts-toggle.sh [on|off|status|toggle]"
        exit 1
        ;;
esac
