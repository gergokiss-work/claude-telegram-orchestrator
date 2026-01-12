#!/bin/bash
# TTS Writer for Claude Code
# Writes a summary to the TTS queue with session-aware filename
#
# Usage: tts-write.sh "Your summary message"
# Or:    echo "message" | tts-write.sh

TTS_DIR="$HOME/.claude/tts"
QUEUE_DIR="$TTS_DIR/queue"
ENABLED_FILE="$TTS_DIR/enabled"

# Check if TTS is enabled
if [[ ! -f "$ENABLED_FILE" ]]; then
    exit 0
fi

# Ensure queue directory exists
mkdir -p "$QUEUE_DIR"

# Get session name (tmux session or fallback)
get_session_name() {
    if [[ -n "$TMUX" ]]; then
        tmux display-message -p '#S' 2>/dev/null || echo "unknown"
    else
        echo "main"
    fi
}

SESSION=$(get_session_name)
TIMESTAMP=$(date +%s%N | cut -c1-13)  # Millisecond precision
PID=$$

FILENAME="${TIMESTAMP}-${SESSION}-${PID}.txt"
FILEPATH="$QUEUE_DIR/$FILENAME"

# Get message from argument or stdin
if [[ -n "$1" ]]; then
    MESSAGE="$*"
else
    MESSAGE=$(cat)
fi

# Write if we have content
if [[ -n "$MESSAGE" ]]; then
    echo "$MESSAGE" > "$FILEPATH"
    echo "TTS queued: $FILENAME"
fi
