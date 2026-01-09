#!/bin/bash
# session-monitor.sh - Monitor tmux session, use AI to extract clean responses
# v7 - AI-powered extraction for actually usable mobile messages

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

SESSION="$1"

if [[ -z "$SESSION" ]]; then
    echo "Usage: session-monitor.sh <session-name>"
    exit 1
fi

LOG_FILE="$SCRIPT_DIR/logs/monitor-$SESSION.log"

IDLE_COUNT=0
IDLE_THRESHOLD=3
LAST_RESPONSE_HASH=""
LAST_NOTIFY_TIME=0
MIN_NOTIFY_INTERVAL=8

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $SESSION: $*" >> "$LOG_FILE"
}

send_notify() {
    local type="$1"
    local message="$2"
    local now=$(date +%s)

    if [[ $((now - LAST_NOTIFY_TIME)) -lt $MIN_NOTIFY_INTERVAL ]]; then
        log "Skipping (cooldown)"
        return 1
    fi

    if [[ -z "$(echo "$message" | tr -d '[:space:]')" ]]; then
        log "Skipping (empty)"
        return 1
    fi

    "$SCRIPT_DIR/notify.sh" "$type" "$SESSION" "$message"
    LAST_NOTIFY_TIME=$now
    log "Sent: $type"
}

is_working() {
    local output="$1"
    # Check last few lines for active work indicators
    echo "$output" | tail -8 | grep -qE 'Marinating|Thinking\.\.\.|tokens remaining|^⏺ (Bash|Read|Edit|Write|Grep|Glob|Task|Update)'
}

is_at_prompt() {
    local last_line=$(echo "$1" | tail -1)
    # Empty line or prompt indicator means Claude is waiting
    [[ -z "$last_line" ]] || echo "$last_line" | grep -qE '^\s*>\s*$|^\s*$|^❯'
}

log "Starting monitor (v7 - AI extraction)"

while tmux has-session -t "$SESSION" 2>/dev/null; do
    # Capture generous amount of pane content
    output=$(tmux capture-pane -t "$SESSION" -p -S -200 2>/dev/null || echo "")

    if [[ -z "$output" ]]; then
        sleep 2
        continue
    fi

    if is_working "$output"; then
        IDLE_COUNT=0
    elif is_at_prompt "$output"; then
        IDLE_COUNT=$((IDLE_COUNT + 1))

        if [[ $IDLE_COUNT -eq $IDLE_THRESHOLD ]]; then
            # Check if content changed
            hash=$(echo "$output" | md5)
            if [[ "$hash" != "$LAST_RESPONSE_HASH" ]]; then
                LAST_RESPONSE_HASH="$hash"

                log "Claude idle - extracting response"

                # Use AI to extract meaningful response
                if [[ -x "$SCRIPT_DIR/src/ai/extract-response.sh" ]]; then
                    response=$("$SCRIPT_DIR/src/ai/extract-response.sh" "$output" 2>/dev/null)
                else
                    # Fallback: basic cleanup
                    response=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -vE '^⏺|^⎿|^❯' | tail -30)
                fi

                if [[ -n "$response" ]]; then
                    send_notify "update" "$response"
                else
                    log "No meaningful content extracted"
                fi
            else
                log "Same content - skipping"
            fi
        fi
    else
        IDLE_COUNT=0
    fi

    sleep 2
done

log "Session ended"
"$SCRIPT_DIR/notify.sh" "complete" "$SESSION" "Session ended"
rm -f "$SCRIPT_DIR/sessions/$SESSION" "$SCRIPT_DIR/sessions/$SESSION.monitor.pid"
