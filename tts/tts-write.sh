#!/bin/bash
# TTS Writer for Claude Code - with priority queue
# Writes a summary to the TTS queue with priority and session-aware filename
#
# Usage: tts-write.sh "Your summary message"
#        tts-write.sh --priority urgent "Error in claude-3!"
#        tts-write.sh --priority important "Task complete"
#        echo "message" | tts-write.sh
#
# Priority levels:
#   1 = URGENT (errors, blockers) - read first
#   2 = IMPORTANT (task completion, results)
#   3 = ROUTINE (status updates, progress) - default

TTS_DIR="$HOME/.claude/tts"
QUEUE_DIR="$TTS_DIR/queue"
ENABLED_FILE="$TTS_DIR/enabled"

# Check if TTS is enabled
if [[ ! -f "$ENABLED_FILE" ]]; then
    exit 0
fi

# Ensure queue directory exists
mkdir -p "$QUEUE_DIR"

# Parse arguments
PRIORITY=3  # Default: ROUTINE
while [[ $# -gt 0 ]]; do
    case "$1" in
        --priority|-p)
            case "$2" in
                urgent|error|1)    PRIORITY=1 ;;
                important|done|2)  PRIORITY=2 ;;
                routine|status|3)  PRIORITY=3 ;;
                *)                 PRIORITY=3 ;;
            esac
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

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

# New filename format: PRIORITY-TIMESTAMP-SESSION-PID.txt
FILENAME="${PRIORITY}-${TIMESTAMP}-${SESSION}-${PID}.txt"
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
    local_priority_name="ROUTINE"
    case "$PRIORITY" in
        1) local_priority_name="URGENT" ;;
        2) local_priority_name="IMPORTANT" ;;
    esac
    echo "TTS queued [$local_priority_name]: $FILENAME"
fi
