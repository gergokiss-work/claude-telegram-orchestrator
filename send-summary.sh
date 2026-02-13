#!/bin/bash
# send-summary.sh - Send a summary to Telegram immediately
# Usage: send-summary.sh "Your summary message here"
#        send-summary.sh --session claude-1 "Your message"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSIONS_DIR="$SCRIPT_DIR/sessions"

[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

# Parse args - check for --session flag
SESSION_OVERRIDE=""
if [[ "$1" == "--session" ]]; then
    SESSION_OVERRIDE="$2"
    shift 2
fi

MESSAGE="$1"
[[ -z "$MESSAGE" ]] && exit 0

mkdir -p "$SESSIONS_DIR"

# Determine session name
if [[ -n "$SESSION_OVERRIDE" ]]; then
    SESSION="$SESSION_OVERRIDE"
elif [[ -n "$TMUX" ]]; then
    # Running in tmux - use tmux session name
    SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "claude")
elif [[ -n "$CLAUDE_SESSION" ]]; then
    # Check for env var set by orchestrator
    SESSION="$CLAUDE_SESSION"
else
    # Running outside tmux (e.g., Cursor terminal)
    # Use a persistent ID based on this terminal session

    # Get TTY as identifier (or PID if no TTY)
    TTY_ID=$(tty 2>/dev/null | sed 's|/dev/||; s|/|-|g' || echo "pid-$$")

    # Check if we already have an ID for this TTY
    CURSOR_ID_FILE="$SESSIONS_DIR/.claude-cursor-tty-map"
    touch "$CURSOR_ID_FILE"

    # Look up existing ID for this TTY
    EXISTING_ID=$(grep "^$TTY_ID:" "$CURSOR_ID_FILE" 2>/dev/null | cut -d: -f2)

    if [[ -n "$EXISTING_ID" ]]; then
        SESSION="$EXISTING_ID"
    else
        # Find next available cursor number
        NEXT_NUM=1
        while [[ -f "$SESSIONS_DIR/claude-cursor-$NEXT_NUM" ]] || grep -q ":claude-cursor-$NEXT_NUM$" "$CURSOR_ID_FILE" 2>/dev/null; do
            NEXT_NUM=$((NEXT_NUM + 1))
        done

        SESSION="claude-cursor-$NEXT_NUM"

        # Register this TTY with the new ID
        echo "$TTY_ID:$SESSION" >> "$CURSOR_ID_FILE"
    fi

    # Create/update session file with TTY info for potential reply routing
    echo "tty=$TTY_ID" > "$SESSIONS_DIR/$SESSION"
    echo "pid=$$" >> "$SESSIONS_DIR/$SESSION"
    echo "started=$(date -Iseconds)" >> "$SESSIONS_DIR/$SESSION"
fi

FORMATTED="📝 <b>[$SESSION]</b>

$MESSAGE"

if [[ -n "$TELEGRAM_CHAT_ID" && -n "$TELEGRAM_BOT_TOKEN" ]]; then
    # Telegram message limit
    MAX_LEN=4096
    HEADER="📝 <b>[$SESSION]</b>

"
    HEADER_LEN=${#HEADER}

    # Send function (handles one chunk)
    send_chunk() {
        local text="$1"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{
                \"chat_id\": \"$TELEGRAM_CHAT_ID\",
                \"text\": $(printf '%s' "$text" | jq -Rs .),
                \"parse_mode\": \"HTML\"
            }" > /dev/null
    }

    if [[ ${#FORMATTED} -le $MAX_LEN ]]; then
        # Fits in one message
        send_chunk "$FORMATTED"
    else
        # Split into parts — break on newlines to keep formatting clean
        PART_NUM=1
        REMAINING="$MESSAGE"
        # Available space per part: limit minus header minus " (N/M)" suffix
        AVAIL=$((MAX_LEN - HEADER_LEN - 20))

        while [[ -n "$REMAINING" ]]; do
            if [[ ${#REMAINING} -le $AVAIL ]]; then
                CHUNK="$REMAINING"
                REMAINING=""
            else
                # Find last newline within the available space
                CHUNK="${REMAINING:0:$AVAIL}"
                BREAK_POS=$(printf '%s' "$CHUNK" | grep -b -o $'\n' | tail -1 | cut -d: -f1)
                if [[ -n "$BREAK_POS" ]] && [[ "$BREAK_POS" -gt $((AVAIL / 3)) ]]; then
                    # Break at last newline (if it's not too early in the chunk)
                    CHUNK="${REMAINING:0:$((BREAK_POS + 1))}"
                fi
                REMAINING="${REMAINING:${#CHUNK}}"
            fi

            # Count total parts (estimate)
            TOTAL_EST=$(( (${#MESSAGE} + AVAIL - 1) / AVAIL ))
            [[ $TOTAL_EST -lt $PART_NUM ]] && TOTAL_EST=$PART_NUM

            if [[ $TOTAL_EST -gt 1 ]]; then
                PART_HEADER="📝 <b>[$SESSION]</b> (${PART_NUM}/${TOTAL_EST})

"
            else
                PART_HEADER="$HEADER"
            fi

            send_chunk "${PART_HEADER}${CHUNK}"
            PART_NUM=$((PART_NUM + 1))
            # Small delay between parts to maintain order
            [[ -n "$REMAINING" ]] && sleep 0.3
        done
    fi

    # Also send as voice message (async, non-blocking)
    VOICE_SCRIPT="$SCRIPT_DIR/send-voice.sh"
    if [[ -x "$VOICE_SCRIPT" ]]; then
        # Strip HTML tags for cleaner speech
        VOICE_TEXT=$(echo "$MESSAGE" | sed 's/<[^>]*>//g' | sed 's/&amp;/and/g' | sed 's/&lt;/</g' | sed 's/&gt;/>/g')
        ( "$VOICE_SCRIPT" --session "$SESSION" "$VOICE_TEXT" ) &>/dev/null &
    fi
fi
