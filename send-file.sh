#!/bin/bash
# send-file.sh - Send a file (PDF, image, etc.) to Telegram
# Usage: send-file.sh /path/to/file.pdf
#        send-file.sh --session claude-1 /path/to/file.pdf "Optional caption"
#        send-file.sh --session claude-1 --caption "Here's the report" /path/to/report.pdf

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

# Parse args
SESSION_OVERRIDE=""
CAPTION=""
FILE_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)
            SESSION_OVERRIDE="$2"
            shift 2
            ;;
        --caption)
            CAPTION="$2"
            shift 2
            ;;
        *)
            if [[ -z "$FILE_PATH" ]]; then
                FILE_PATH="$1"
            elif [[ -z "$CAPTION" ]]; then
                CAPTION="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$FILE_PATH" ]]; then
    echo "Usage: send-file.sh [--session NAME] [--caption TEXT] /path/to/file [caption]" >&2
    exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
    echo "ERROR: File not found: $FILE_PATH" >&2
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

# Build caption
if [[ -n "$CAPTION" ]]; then
    FULL_CAPTION="📎 <b>[$SESSION]</b>

$CAPTION"
else
    FILENAME=$(basename "$FILE_PATH")
    FULL_CAPTION="📎 <b>[$SESSION]</b> $FILENAME"
fi

# Detect file type for best Telegram method
MIME_TYPE=$(file --brief --mime-type "$FILE_PATH" 2>/dev/null || echo "application/octet-stream")
EXTENSION="${FILE_PATH##*.}"
EXTENSION_LOWER=$(echo "$EXTENSION" | tr '[:upper:]' '[:lower:]')

# Choose API method based on file type
case "$MIME_TYPE" in
    image/jpeg|image/png|image/gif|image/webp)
        # Send as photo (compressed, inline preview)
        API_METHOD="sendPhoto"
        FILE_FIELD="photo"
        ;;
    video/mp4|video/quicktime|video/webm)
        # Send as video
        API_METHOD="sendVideo"
        FILE_FIELD="video"
        ;;
    audio/mpeg|audio/mp3|audio/ogg|audio/flac)
        # Send as audio
        API_METHOD="sendAudio"
        FILE_FIELD="audio"
        ;;
    *)
        # Send as document (PDF, zip, etc. - preserves original)
        API_METHOD="sendDocument"
        FILE_FIELD="document"
        ;;
esac

# Override: force document mode for specific extensions (preserves quality)
case "$EXTENSION_LOWER" in
    pdf|zip|tar|gz|csv|json|xml|xlsx|docx|pptx|txt|md|log)
        API_METHOD="sendDocument"
        FILE_FIELD="document"
        ;;
esac

# File size check (Telegram limit: 50MB for bot API)
FILE_SIZE=$(stat -f %z "$FILE_PATH" 2>/dev/null || stat -c %s "$FILE_PATH" 2>/dev/null || echo "0")
MAX_SIZE=$((50 * 1024 * 1024))
if [[ "$FILE_SIZE" -gt "$MAX_SIZE" ]]; then
    echo "ERROR: File too large ($(( FILE_SIZE / 1024 / 1024 ))MB). Telegram limit is 50MB." >&2
    exit 1
fi

# Send the file
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${API_METHOD}" \
    -F "chat_id=$TELEGRAM_CHAT_ID" \
    -F "${FILE_FIELD}=@${FILE_PATH}" \
    -F "caption=${FULL_CAPTION}" \
    -F "parse_mode=HTML")

if echo "$RESPONSE" | jq -e '.ok' &>/dev/null; then
    FILENAME=$(basename "$FILE_PATH")
    echo "File sent successfully: $FILENAME ($API_METHOD)"
else
    echo "ERROR: Failed to send file" >&2
    echo "$RESPONSE" | jq -r '.description // "Unknown error"' 2>/dev/null >&2
    exit 1
fi
