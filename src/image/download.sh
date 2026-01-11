#!/bin/bash
# download.sh - Download image from Telegram and return local path
# Usage: download.sh <file_id> <message_id>
# Returns: path to downloaded image

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$ROOT_DIR/.env.local" 2>/dev/null

FILE_ID="$1"
MESSAGE_ID="$2"

if [[ -z "$FILE_ID" ]]; then
    echo "ERROR: No file_id provided"
    exit 1
fi

# Create images directory
IMAGES_DIR="$ROOT_DIR/images"
mkdir -p "$IMAGES_DIR"

# Get file path from Telegram
FILE_INFO=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=$FILE_ID")

if [[ $(echo "$FILE_INFO" | jq -r '.ok') != "true" ]]; then
    echo "ERROR: Failed to get file info"
    exit 1
fi

FILE_PATH=$(echo "$FILE_INFO" | jq -r '.result.file_path')

if [[ -z "$FILE_PATH" || "$FILE_PATH" == "null" ]]; then
    echo "ERROR: No file path in response"
    exit 1
fi

# Extract extension
EXT="${FILE_PATH##*.}"
[[ -z "$EXT" ]] && EXT="jpg"

# Generate local filename
TIMESTAMP=$(date +%s)
LOCAL_FILE="$IMAGES_DIR/img_${MESSAGE_ID}_${TIMESTAMP}.${EXT}"

# Download the file
DOWNLOAD_URL="https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${FILE_PATH}"
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$LOCAL_FILE" "$DOWNLOAD_URL")

if [[ "$HTTP_CODE" != "200" ]]; then
    rm -f "$LOCAL_FILE"
    echo "ERROR: Download failed with HTTP $HTTP_CODE"
    exit 1
fi

# Verify file exists and has content
if [[ ! -s "$LOCAL_FILE" ]]; then
    rm -f "$LOCAL_FILE"
    echo "ERROR: Downloaded file is empty"
    exit 1
fi

echo "$LOCAL_FILE"
