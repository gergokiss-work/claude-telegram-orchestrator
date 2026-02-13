#!/bin/bash
# TTS Reader v3.0 - Atomic lock, singleton queue drain
# Called by Claude Code Stop hook. Multiple instances may fire simultaneously.
# Uses mkdir for atomic locking — only ONE reader speaks at a time.
# If lock is held, this instance exits silently (the running reader drains the queue).

TTS_DIR="$HOME/.claude/tts"
QUEUE_DIR="$TTS_DIR/queue"
ENABLED_FILE="$TTS_DIR/enabled"
LOCK_DIR="$TTS_DIR/reading.lockdir"
LOG_FILE="$TTS_DIR/reader.log"

VOICE="${CLAUDE_TTS_VOICE:-Daniel}"
RATE="${CLAUDE_TTS_RATE:-200}"
LOCK_STALE=120

log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if TTS is enabled
[[ ! -f "$ENABLED_FILE" ]] && exit 0
[[ ! -d "$QUEUE_DIR" ]] && exit 0

# Quick check — empty queue means nothing to do
PENDING=$(ls -1 "$QUEUE_DIR"/*.txt 2>/dev/null | wc -l | tr -d ' ')
[[ "$PENDING" -eq 0 ]] && exit 0

# Atomic lock using mkdir (atomic on all POSIX systems, no race condition)
# If another reader is already running, just exit — it will drain the queue
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Lock exists — check if stale
    if [[ -d "$LOCK_DIR" ]]; then
        LOCK_PID_FILE="$LOCK_DIR/pid"
        if [[ -f "$LOCK_PID_FILE" ]]; then
            LOCK_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null)
            LOCK_AGE=$(($(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)))

            if [[ -n "$LOCK_PID" ]] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
                log "Removing orphaned lock (PID $LOCK_PID dead)"
                rm -rf "$LOCK_DIR"
                mkdir "$LOCK_DIR" 2>/dev/null || exit 0
            elif [[ $LOCK_AGE -gt $LOCK_STALE ]]; then
                log "Removing stale lock (age: ${LOCK_AGE}s)"
                rm -rf "$LOCK_DIR"
                mkdir "$LOCK_DIR" 2>/dev/null || exit 0
            else
                # Lock held by live process — it will drain the queue for us
                exit 0
            fi
        else
            rm -rf "$LOCK_DIR"
            mkdir "$LOCK_DIR" 2>/dev/null || exit 0
        fi
    fi
fi

# We own the lock
echo $$ > "$LOCK_DIR/pid"
cleanup() { rm -rf "$LOCK_DIR"; }
trap cleanup EXIT

log "Lock acquired by PID $$"

# Drain the queue — loop until empty for 2 consecutive checks
# (catches items written while we're speaking)
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
        AUDIO_FILE="/tmp/tts-$$.aiff"
        say -v "$VOICE" -r "$RATE" -o "$AUDIO_FILE" -f "$NEXT_FILE" 2>/dev/null
        afplay "$AUDIO_FILE" 2>/dev/null
        rm -f "$AUDIO_FILE"
        sleep 0.5
    fi

    rm -f "$NEXT_FILE"
    log "Completed: $FILENAME"
done

log "Queue drained, releasing lock"
