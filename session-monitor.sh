#!/bin/bash
# session-monitor.sh - Monitor a tmux session for Claude state changes

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

SESSION="$1"

if [[ -z "$SESSION" ]]; then
    echo "Usage: session-monitor.sh <session-name>"
    exit 1
fi

LAST_HASH=""
LAST_NOTIFY_TIME=0
MIN_NOTIFY_INTERVAL=10

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $SESSION: $*"
}

notify_if_needed() {
    local type="$1"
    local message="$2"
    local current_time=$(date +%s)

    if [[ $((current_time - LAST_NOTIFY_TIME)) -lt $MIN_NOTIFY_INTERVAL ]]; then
        log "Skipping notification (rate limited)"
        return
    fi

    "$SCRIPT_DIR/notify.sh" "$type" "$SESSION" "$message"
    LAST_NOTIFY_TIME=$current_time
}

log "Starting monitor"

while tmux has-session -t "$SESSION" 2>/dev/null; do
    output=$(tmux capture-pane -t "$SESSION" -p -S -100 2>/dev/null || echo "")

    if [[ -z "$output" ]]; then
        sleep 2
        continue
    fi

    current_hash=$(echo "$output" | md5 2>/dev/null)

    if [[ "$current_hash" != "$LAST_HASH" ]]; then
        LAST_HASH="$current_hash"
        last_lines=$(echo "$output" | grep -v '^$' | tail -20)

        # Check for questions
        if echo "$last_lines" | grep -qE '^\s*\?|^>.*\?$|Do you want|Should I|Would you like|Please confirm|y/n|yes/no|\[Y/n\]|\[y/N\]'; then
            log "Detected question"
            notify_if_needed "waiting" "$(echo "$last_lines" | tail -10)"
        fi

        # Check for permission requests
        if echo "$last_lines" | grep -qE 'Allow|Deny|permission|approve|Press.*to'; then
            log "Detected permission request"
            notify_if_needed "waiting" "$(echo "$last_lines" | tail -5)"
        fi

        # Check for multi-select menus
        if echo "$last_lines" | grep -qE '^\s*[❯>]\s+\w|^\s*\[\s*[x ]?\s*\]|^\s*[0-9]+[.):]\s+\w'; then
            log "Detected multi-select menu"
            options=$(echo "$last_lines" | grep -E '^\s*[❯> ]\s+\w|^\s*\[\s*[x ]?\s*\]|^\s*[0-9]+[.):]\s+\w' | head -10)
            formatted="Options:
"
            i=1
            while IFS= read -r line; do
                clean=$(echo "$line" | sed 's/^[[:space:]]*[❯>]//' | sed 's/^\[[^]]*\]//' | xargs)
                if [[ -n "$clean" ]]; then
                    formatted+="$i. $clean
"
                    i=$((i+1))
                fi
            done <<< "$options"
            formatted+="
Reply: /<session> <number>"
            notify_if_needed "waiting" "$formatted"
        fi

        # Check for Claude response
        if echo "$last_lines" | grep -qE '^⏺|^✓|^✗'; then
            log "Detected Claude response"
            response=$(echo "$last_lines" | grep -A5 '^⏺' | head -6)
            notify_if_needed "update" "$response"
        fi

        # Check for completion
        if echo "$last_lines" | grep -qE 'Task completed|Done\.|Finished|Session ended|goodbye|exiting'; then
            log "Detected completion"
            notify_if_needed "complete" "$(echo "$last_lines" | tail -5)"
        fi

        # Check for errors
        if echo "$last_lines" | grep -qiE 'error:|failed|exception|fatal'; then
            log "Detected error"
            notify_if_needed "error" "$(echo "$last_lines" | grep -iE 'error:|failed|exception|fatal' | tail -5)"
        fi
    fi

    sleep 2
done

log "Session ended"

last_output=$(tmux capture-pane -t "$SESSION" -p -S -30 2>/dev/null | grep -v '^$' | tail -10)
"$SCRIPT_DIR/notify.sh" "complete" "$SESSION" "Session ended.
$last_output"

rm -f "$SCRIPT_DIR/sessions/$SESSION" "$SCRIPT_DIR/sessions/$SESSION.monitor.pid"
log "Monitor finished"
