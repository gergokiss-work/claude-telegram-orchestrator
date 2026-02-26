#!/bin/bash
# TTS Reader v4.0 - flock-based singleton queue drain
# Called by Claude Code Stop hook. Multiple instances may fire simultaneously.
# Uses flock for atomic locking — only ONE reader speaks at a time.

TTS_DIR="$HOME/.claude/tts"
QUEUE_DIR="$TTS_DIR/queue"
ENABLED_FILE="$TTS_DIR/enabled"
LOCK_FILE="$TTS_DIR/reader.lock"
LOG_FILE="$TTS_DIR/reader.log"

VOICE="${CLAUDE_TTS_VOICE:-Daniel}"
RATE="${CLAUDE_TTS_RATE:-200}"

log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if TTS is enabled
[[ ! -f "$ENABLED_FILE" ]] && exit 0
[[ ! -d "$QUEUE_DIR" ]] && exit 0

# Quick check — empty queue means nothing to do
PENDING=$(ls -1 "$QUEUE_DIR"/*.txt 2>/dev/null | wc -l | tr -d ' ')
[[ "$PENDING" -eq 0 ]] && exit 0

# flock: try to acquire exclusive lock, exit immediately if held
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    # Another reader is draining the queue — exit silently
    exit 0
fi

log "Lock acquired by PID $$"

# Drain the queue — loop until empty for 2 consecutive checks
EMPTY_ROUNDS=0
while [[ $EMPTY_ROUNDS -lt 2 ]]; do
    NEXT_FILE=$(ls -1 "$QUEUE_DIR"/*.txt 2>/dev/null | sort | head -1)

    if [[ -z "$NEXT_FILE" ]] || [[ ! -f "$NEXT_FILE" ]]; then
        EMPTY_ROUNDS=$((EMPTY_ROUNDS + 1))
        sleep 0.5
        continue
    fi

    EMPTY_ROUNDS=0

    FILENAME=$(basename "$NEXT_FILE")
    PRIORITY=$(echo "$FILENAME" | cut -d'-' -f1)
    PRIORITY_LABEL="ROUTINE"
    case "$PRIORITY" in
        1) PRIORITY_LABEL="URGENT" ;;
        2) PRIORITY_LABEL="IMPORTANT" ;;
    esac

    log "Reading [$PRIORITY_LABEL]: $FILENAME"

    if [[ -s "$NEXT_FILE" ]]; then
        # Wait for any running say/afplay to finish — prevents overlap with send-voice.sh
        while pgrep -x "say" &>/dev/null || pgrep -x "afplay" &>/dev/null; do
            sleep 0.5
        done
        AUDIO_FILE="/tmp/tts-$$.aiff"
        say -v "$VOICE" -r "$RATE" -o "$AUDIO_FILE" -f "$NEXT_FILE" 2>/dev/null
        afplay "$AUDIO_FILE" 2>/dev/null
        rm -f "$AUDIO_FILE"
        sleep 0.3
    fi

    rm -f "$NEXT_FILE"
    log "Completed: $FILENAME"
done

log "Queue drained, releasing lock"
