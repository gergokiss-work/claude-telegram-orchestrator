#!/bin/bash
# send-summary.sh - Send a summary to Telegram immediately
# Usage: send-summary.sh "Your summary message here"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

MESSAGE="$1"
[[ -z "$MESSAGE" ]] && exit 0

# Get session name from tmux if running inside one
SESSION="claude"
if [[ -n "$TMUX" ]]; then
    SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "claude")
fi

FORMATTED="📝 <b>[$SESSION]</b>

$MESSAGE"

if [[ -n "$TELEGRAM_CHAT_ID" && -n "$TELEGRAM_BOT_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"text\": $(echo "$FORMATTED" | jq -Rs .),
            \"parse_mode\": \"HTML\"
        }" > /dev/null
fi
