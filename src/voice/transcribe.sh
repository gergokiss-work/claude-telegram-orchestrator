#!/bin/bash
# transcribe.sh - Download and transcribe Telegram voice message using OpenAI Whisper
# Usage: transcribe.sh <file_id> <message_id>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../.."

# Source config
[[ -f "$ROOT_DIR/.env.local" ]] && source "$ROOT_DIR/.env.local"
[[ -f "$ROOT_DIR/config.env" ]] && source "$ROOT_DIR/config.env"

FILE_ID="$1"
MESSAGE_ID="${2:-$(date +%s)}"

TEMP_DIR="$ROOT_DIR/data/temp"
mkdir -p "$TEMP_DIR"

LOG_FILE="$ROOT_DIR/logs/voice.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] VOICE: $*" >> "$LOG_FILE"
}

cleanup() {
    rm -f "$TEMP_DIR/voice_${MESSAGE_ID}."* 2>/dev/null || true
}

# Cleanup on exit
trap cleanup EXIT

log "Processing voice message: file_id=$FILE_ID"

# Step 1: Get file path from Telegram
file_info=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${FILE_ID}")
file_path=$(echo "$file_info" | jq -r '.result.file_path // empty')

if [[ -z "$file_path" ]]; then
    log "ERROR: Could not get file path from Telegram"
    echo "ERROR: Could not get file path"
    exit 1
fi

log "Got file path: $file_path"

# Step 2: Download the voice file (OGA/OGG format)
voice_file="$TEMP_DIR/voice_${MESSAGE_ID}.oga"
curl -s "https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${file_path}" -o "$voice_file"

if [[ ! -f "$voice_file" ]] || [[ ! -s "$voice_file" ]]; then
    log "ERROR: Failed to download voice file"
    echo "ERROR: Failed to download"
    exit 1
fi

log "Downloaded voice file: $(du -h "$voice_file" | cut -f1)"

# Step 3: Convert to format Whisper likes (mp3 or wav)
# Whisper accepts mp3, wav, m4a, webm, etc.
converted_file="$TEMP_DIR/voice_${MESSAGE_ID}.mp3"

if command -v ffmpeg &>/dev/null; then
    ffmpeg -i "$voice_file" -ar 16000 -ac 1 -y "$converted_file" 2>/dev/null
    log "Converted to mp3"
else
    # If no ffmpeg, try sending OGA directly (Whisper might accept it)
    converted_file="$voice_file"
    log "No ffmpeg, using original format"
fi

# Step 4: Transcribe with OpenAI Whisper
if [[ -z "$OPENAI_API_KEY" ]]; then
    log "ERROR: OPENAI_API_KEY not set"
    echo "ERROR: OPENAI_API_KEY not configured"
    exit 1
fi

log "Calling Whisper API..."

transcription=$(curl -s "https://api.openai.com/v1/audio/transcriptions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F "file=@$converted_file" \
    -F "model=whisper-1" \
    -F "language=en" \
    -F "response_format=text")

if [[ -z "$transcription" ]]; then
    log "ERROR: Empty transcription"
    echo "ERROR: Transcription failed"
    exit 1
fi

log "Transcription successful: ${transcription:0:50}..."

# Output the transcription
echo "$transcription"
