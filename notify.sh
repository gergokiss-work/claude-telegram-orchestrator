#!/bin/bash
# notify.sh - Send notifications to Telegram

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

TYPE="${1:-update}"
SESSION="${2:-unknown}"
MESSAGE="${3:-}"

if [[ -z "$MESSAGE" ]]; then
    MESSAGE=$(cat)
fi

# Truncate if too long
if [[ ${#MESSAGE} -gt 3500 ]]; then
    MESSAGE="${MESSAGE:0:3500}...[truncated]"
fi

case "$TYPE" in
    waiting) EMOJI="❓"; HEADER="Waiting for input" ;;
    complete) EMOJI="✅"; HEADER="Session complete" ;;
    update) EMOJI="📝"; HEADER="Update" ;;
    error) EMOJI="❌"; HEADER="Error" ;;
    new) EMOJI="🚀"; HEADER="New session" ;;
    *) EMOJI="📌"; HEADER="$TYPE" ;;
esac

FORMATTED="$EMOJI <b>[$SESSION]</b> $HEADER

<pre>$(echo "$MESSAGE" | head -50)</pre>"

if [[ -n "$TELEGRAM_CHAT_ID" && -n "$TELEGRAM_BOT_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"text\": $(echo "$FORMATTED" | jq -Rs .),
            \"parse_mode\": \"HTML\"
        }" > /dev/null
fi

echo "Notification sent: $TYPE for $SESSION"
