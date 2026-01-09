#!/bin/bash
# session-monitor.sh - Monitor a tmux session for Claude responses
# Only sends notification when Claude is TRULY done (stable idle for 6+ seconds)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source configs
[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

SESSION="$1"

if [[ -z "$SESSION" ]]; then
    echo "Usage: session-monitor.sh <session-name>"
    exit 1
fi

LOG_FILE="$SCRIPT_DIR/logs/monitor-$SESSION.log"

# State tracking
IDLE_COUNT=0
IDLE_THRESHOLD=3           # Need 3 consecutive idle checks (6 seconds) before sending
LAST_RESPONSE_HASH=""
LAST_NOTIFY_TIME=0
MIN_NOTIFY_INTERVAL=15     # Minimum 15 seconds between notifications

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $SESSION: $*" >> "$LOG_FILE"
}

# Send notification with cooldown
send_notify() {
    local type="$1"
    local message="$2"
    local now=$(date +%s)

    if [[ $((now - LAST_NOTIFY_TIME)) -lt $MIN_NOTIFY_INTERVAL ]]; then
        log "Skipping (cooldown: $((MIN_NOTIFY_INTERVAL - now + LAST_NOTIFY_TIME))s remaining)"
        return 1
    fi

    # Validate message has actual content (not just dashes/boxes/whitespace)
    local content_check=$(echo "$message" | grep -vE '^[\s─━│┃╭╰├┤┬┴┼▸▹►▶→_\-]*$' | grep -vE '^\s*$' | head -1)
    if [[ -z "$content_check" ]]; then
        log "Skipping (no meaningful content)"
        return 1
    fi

    "$SCRIPT_DIR/notify.sh" "$type" "$SESSION" "$message"
    LAST_NOTIFY_TIME=$now
    log "Sent notification: $type (${#message} chars)"
    return 0
}

# Check if Claude is actively working
is_working() {
    local output="$1"
    local last_lines=$(echo "$output" | tail -10)

    # Check for active processing indicators
    if echo "$last_lines" | grep -qE 'Marinating|Thinking\.\.\.|tokens remaining'; then
        return 0  # Working
    fi

    # Check for tool execution
    if echo "$last_lines" | grep -qE '^⏺ (Bash|Read|Edit|Write|Grep|Glob|Task|WebFetch|WebSearch|TodoWrite)'; then
        return 0  # Working
    fi

    return 1  # Not working
}

# Check if at input prompt (Claude waiting for user)
is_at_prompt() {
    local output="$1"
    local last_line=$(echo "$output" | tail -1)

    # Empty prompt or just whitespace at end means waiting for input
    if echo "$last_line" | grep -qE '^\s*>\s*$|^\s*$'; then
        return 0
    fi

    return 1
}

# Extract Claude's meaningful text response
extract_response() {
    local raw="$1"

    echo "$raw" | \
        sed 's/\x1b\[[0-9;]*m//g' | \
        sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | \
        grep -vE '^\s*$' | \
        grep -vE '^[╭╰│─├┤┬┴┼━┃┏┓┗┛▸▹►▶→_\-]+' | \
        grep -vE '[╭╰│─├┤┬┴┼━┃┏┓┗┛_\-]+\s*$' | \
        grep -vE 'Marinating|Thinking|tokens|bypass permissions|esc to interrupt|shift.tab|to cycle' | \
        grep -vE '^⏺ (Bash|Read|Edit|Write|Grep|Glob|Task|Update|WebFetch|WebSearch|TodoWrite)' | \
        grep -vE '^\s*(Running|Completed|Output)\.*\s*$' | \
        grep -vE '^\s*[>❯]\s*$' | \
        grep -vE '^\[\s*(completed|in_progress|pending)\s*\]' | \
        grep -vE '^\s*□\s*\[' | \
        tail -40 | \
        cat -s
}

log "Starting monitor (v5 - strict content validation)"

while tmux has-session -t "$SESSION" 2>/dev/null; do
    # Capture pane
    output=$(tmux capture-pane -t "$SESSION" -p -S -100 2>/dev/null || echo "")

    if [[ -z "$output" ]]; then
        sleep 2
        continue
    fi

    # Check current state
    if is_working "$output"; then
        IDLE_COUNT=0
        # Don't log every working state to reduce noise
    elif is_at_prompt "$output"; then
        IDLE_COUNT=$((IDLE_COUNT + 1))

        # Only send after stable idle (not just a brief pause)
        if [[ $IDLE_COUNT -eq $IDLE_THRESHOLD ]]; then
            response=$(extract_response "$output")

            if [[ -n "$response" ]]; then
                # Check if this is new content
                hash=$(echo "$response" | md5)
                if [[ "$hash" != "$LAST_RESPONSE_HASH" ]]; then
                    LAST_RESPONSE_HASH="$hash"

                    # Use AI formatting for long responses
                    if [[ ${#response} -gt 500 ]] && [[ -x "$SCRIPT_DIR/src/ai/format-output.sh" ]]; then
                        formatted=$("$SCRIPT_DIR/src/ai/format-output.sh" "$response" 2>/dev/null)
                        if [[ -n "$formatted" ]]; then
                            response="$formatted"
                        fi
                    fi

                    log "Claude finished - sending response (${#response} chars)"
                    send_notify "update" "$response"
                else
                    log "Same content as before - skipping"
                fi
            else
                log "No meaningful content extracted"
            fi
        fi
    else
        # Uncertain state - could be mid-response
        IDLE_COUNT=0
    fi

    sleep 2
done

log "Session ended"
"$SCRIPT_DIR/notify.sh" "complete" "$SESSION" "Session ended"
rm -f "$SCRIPT_DIR/sessions/$SESSION" "$SCRIPT_DIR/sessions/$SESSION.monitor.pid"
log "Monitor finished"
