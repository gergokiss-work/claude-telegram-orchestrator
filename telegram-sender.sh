#!/bin/bash
# Telegram Sender for Claude Code
# Reads summaries from queue and sends to Telegram
#
# Summaries go to: ~/.claude/telegram-orchestrator/queue/*.txt
# Lock prevents concurrent sends

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUEUE_DIR="$SCRIPT_DIR/queue"
ENABLED_FILE="$SCRIPT_DIR/enabled"
LOCK_FILE="$SCRIPT_DIR/sending.lock"

# Source config for Telegram credentials
[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

# Check if enabled
[[ ! -f "$ENABLED_FILE" ]] && exit 0

# Check if queue dir exists
[[ ! -d "$QUEUE_DIR" ]] && exit 0

# Check for lock (another sender is active)
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0  # Another sender is active
    fi
    rm -f "$LOCK_FILE"  # Stale lock
fi

# Get oldest file in queue
SUMMARY_FILE=$(ls -1t "$QUEUE_DIR"/*.txt 2>/dev/null | tail -1)
[[ -z "$SUMMARY_FILE" ]] && exit 0

# Create lock
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

# Read content
MESSAGE=$(cat "$SUMMARY_FILE")
[[ -z "$MESSAGE" ]] && { rm -f "$SUMMARY_FILE"; exit 0; }

# Get session name from tmux if running inside one, otherwise use "claude"
SESSION="claude"
if [[ -n "$TMUX" ]]; then
    SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "claude")
fi

# Format message
FORMATTED="📝 <b>[$SESSION]</b>

$MESSAGE"

# Send to Telegram
if [[ -n "$TELEGRAM_CHAT_ID" && -n "$TELEGRAM_BOT_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"text\": $(echo "$FORMATTED" | jq -Rs .),
            \"parse_mode\": \"HTML\"
        }" > /dev/null
fi

# Remove after sending
rm -f "$SUMMARY_FILE"
