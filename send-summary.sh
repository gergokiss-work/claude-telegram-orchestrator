#!/bin/bash
# send-summary.sh - Send a summary to Telegram immediately
# Usage: send-summary.sh "Your summary message here"
#        send-summary.sh --session claude-1 "Your message"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSIONS_DIR="$SCRIPT_DIR/sessions"

[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

# Parse args - check for --session, --voice, --no-voice flags
SESSION_OVERRIDE=""
SEND_VOICE=true  # Voice is ON by default: every summary gets a voice message
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)
            SESSION_OVERRIDE="$2"
            shift 2
            ;;
        --voice)
            SEND_VOICE=true
            shift
            ;;
        --no-voice)
            SEND_VOICE=false
            shift
            ;;
        *)
            break
            ;;
    esac
done

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

    # Write event file for refinement-loop daemon
    # This signals that an agent sent a summary and starts the reply timer
    REFINEMENT_DIR="$HOME/.claude/refinement-loop"
    if [[ -d "$REFINEMENT_DIR/events" ]]; then
        echo "{\"session\":\"$SESSION\",\"timestamp\":$(date +%s)}" > "$REFINEMENT_DIR/events/${SESSION}.event"
    fi

    # Notify watch via Mac API (non-blocking, best-effort)
    WATCH_API_ENV="$HOME/work/gergo/watchos-app/mac-api/.env"
    if [[ -f "$WATCH_API_ENV" ]]; then
        (
            WATCH_TOKEN=$(grep '^API_TOKEN=' "$WATCH_API_ENV" | cut -d= -f2)
            WATCH_PORT=$(grep '^PORT=' "$WATCH_API_ENV" | cut -d= -f2)
            WATCH_PORT="${WATCH_PORT:-8081}"
            # Extract title from first bold tag (e.g., "Watch Notifications Fixed")
            NOTIF_TITLE=$(echo "$MESSAGE" | sed -n 's/.*<b>\([^<]*\)<\/b>.*/\1/p' | head -1)
            [[ -z "$NOTIF_TITLE" ]] && NOTIF_TITLE="$SESSION finished"
            # Watch body: extract first bullet point after Result, or first meaningful line
            # Keep it very short (~80 chars) for the tiny watch screen
            NOTIF_BODY=$(echo "$MESSAGE" | sed 's/<[^>]*>//g' | sed 's/&amp;/and/g' | grep -m1 '^\s*•' | sed 's/^\s*•\s*//' | head -c 80)
            # Fallback: grab the line after "Result:" if no bullet found
            if [[ -z "$NOTIF_BODY" ]]; then
                NOTIF_BODY=$(echo "$MESSAGE" | sed 's/<[^>]*>//g' | sed 's/&amp;/and/g' | grep -A1 -i 'result' | tail -1 | sed 's/^\s*//' | head -c 80)
            fi
            # Final fallback: first non-empty line after stripping
            if [[ -z "$NOTIF_BODY" ]]; then
                NOTIF_BODY=$(echo "$MESSAGE" | sed 's/<[^>]*>//g' | sed 's/&amp;/and/g' | sed '/^\s*$/d' | head -1 | head -c 80)
            fi
            curl -s -X POST "http://localhost:${WATCH_PORT}/notifications" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${WATCH_TOKEN}" \
                -d "{\"session\":\"$SESSION\",\"title\":$(printf '%s' "$NOTIF_TITLE" | jq -Rs .),\"body\":$(printf '%s' "$NOTIF_BODY" | jq -Rs .),\"type\":\"task_complete\"}" \
                --connect-timeout 2 --max-time 5 > /dev/null 2>&1
        ) &
    fi

    # Send voice message with every summary (disable with --no-voice)
    if [[ "$SEND_VOICE" == "true" ]]; then
        VOICE_SCRIPT="$SCRIPT_DIR/send-voice.sh"
        if [[ -x "$VOICE_SCRIPT" ]]; then
            # Strip HTML tags for cleaner speech
            VOICE_TEXT=$(echo "$MESSAGE" | sed 's/<[^>]*>//g' | sed 's/&amp;/and/g' | sed 's/&lt;/</g' | sed 's/&gt;/>/g')
            ( "$VOICE_SCRIPT" --session "$SESSION" "$VOICE_TEXT" ) &>/dev/null &
        fi
    fi
fi
