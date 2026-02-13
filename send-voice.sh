#!/bin/bash
# send-voice.sh - Convert text to audio and send as Telegram voice message
# Usage: send-voice.sh "Your message here"
#        send-voice.sh --session claude-0 "Your message here"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

# Check ffmpeg dependency
if ! command -v ffmpeg &>/dev/null; then
    echo "ERROR: ffmpeg is required but not installed." >&2
    echo "Install with: brew install ffmpeg" >&2
    exit 1
fi

# Parse args - check for --session flag
SESSION_OVERRIDE=""
if [[ "$1" == "--session" ]]; then
    SESSION_OVERRIDE="$2"
    shift 2
fi

MESSAGE="$1"
if [[ -z "$MESSAGE" ]]; then
    echo "Usage: send-voice.sh [--session NAME] \"Your message\"" >&2
    exit 1
fi

# Determine session name
if [[ -n "$SESSION_OVERRIDE" ]]; then
    SESSION="$SESSION_OVERRIDE"
elif [[ -n "$TMUX" ]]; then
    SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "claude")
elif [[ -n "$CLAUDE_SESSION" ]]; then
    SESSION="$CLAUDE_SESSION"
else
    SESSION="claude"
fi

# Validate Telegram credentials
if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set in .env.local" >&2
    exit 1
fi

# Truncate text for speech — macOS say handles long text but Telegram voice
# messages over 60s are unwieldy. Cap at ~500 chars (~30 seconds of speech at 200 WPM).
MAX_SPEECH_CHARS=500
SPEECH_TEXT="$MESSAGE"
if [[ ${#SPEECH_TEXT} -gt $MAX_SPEECH_CHARS ]]; then
    # Cut at last sentence boundary within limit
    TRUNCATED="${SPEECH_TEXT:0:$MAX_SPEECH_CHARS}"
    LAST_PERIOD=$(printf '%s' "$TRUNCATED" | grep -b -o '\.' | tail -1 | cut -d: -f1)
    if [[ -n "$LAST_PERIOD" ]] && [[ "$LAST_PERIOD" -gt $((MAX_SPEECH_CHARS / 3)) ]]; then
        SPEECH_TEXT="${TRUNCATED:0:$((LAST_PERIOD + 1))}"
    else
        SPEECH_TEXT="${TRUNCATED}..."
    fi
fi

# Skip if text is effectively empty after stripping
CLEAN_TEXT=$(printf '%s' "$SPEECH_TEXT" | sed 's/[[:space:]]//g')
if [[ ${#CLEAN_TEXT} -lt 5 ]]; then
    echo "SKIP: Text too short for voice message" >&2
    exit 0
fi

# Create temp files
AIFF_FILE=$(mktemp /tmp/voice-XXXXXX.aiff)
OGG_FILE=$(mktemp /tmp/voice-XXXXXX.ogg)
trap "rm -f '$AIFF_FILE' '$OGG_FILE'" EXIT

# Generate audio with macOS say
say -v Daniel -r 200 -o "$AIFF_FILE" "$SPEECH_TEXT"

if [[ ! -s "$AIFF_FILE" ]]; then
    echo "ERROR: Failed to generate audio with 'say'" >&2
    exit 1
fi

# Convert to OGG/Opus (Telegram voice format)
ffmpeg -y -i "$AIFF_FILE" -c:a libopus -b:a 48k -ar 48000 -ac 1 "$OGG_FILE" 2>/dev/null

if [[ ! -s "$OGG_FILE" ]]; then
    echo "ERROR: Failed to convert audio to OGG/Opus format" >&2
    exit 1
fi

# Verify OGG has actual audio content (not 0-second)
OGG_SIZE=$(stat -f %z "$OGG_FILE" 2>/dev/null || echo "0")
if [[ "$OGG_SIZE" -lt 500 ]]; then
    echo "ERROR: Audio file too small (${OGG_SIZE} bytes) — likely empty" >&2
    exit 1
fi

# Caption: short label only (not the full message)
CAPTION="[$SESSION]"

RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendVoice" \
    -F "chat_id=$TELEGRAM_CHAT_ID" \
    -F "voice=@$OGG_FILE" \
    -F "caption=$CAPTION")

if echo "$RESPONSE" | jq -e '.ok' &>/dev/null; then
    echo "Voice message sent successfully"
else
    echo "ERROR: Failed to send voice message" >&2
    echo "$RESPONSE" | jq -r '.description // "Unknown error"' 2>/dev/null >&2
    exit 1
fi
