#!/bin/bash
# TTS Reader v2.0 for Claude Code
# Multi-instance safe: reads summaries sequentially with proper locking
#
# Summaries go to: ~/.claude/tts/queue/TIMESTAMP-SESSION-PID.txt
# Lock ensures sequential reading across all instances

TTS_DIR="$HOME/.claude/tts"
QUEUE_DIR="$TTS_DIR/queue"
ENABLED_FILE="$TTS_DIR/enabled"
LOCK_FILE="$TTS_DIR/reading.lock"
LOG_FILE="$TTS_DIR/reader.log"

VOICE="${CLAUDE_TTS_VOICE:-Daniel}"
RATE="${CLAUDE_TTS_RATE:-200}"
LOCK_TIMEOUT=60  # Max seconds to wait for lock
LOCK_STALE=120   # Seconds before lock considered stale

log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if TTS is enabled
[[ ! -f "$ENABLED_FILE" ]] && exit 0

# Check if queue dir exists
[[ ! -d "$QUEUE_DIR" ]] && exit 0

# Acquire lock with waiting
acquire_lock() {
    local waited=0

    while [[ -f "$LOCK_FILE" ]]; do
        # Check if lock is stale
        if [[ -f "$LOCK_FILE" ]]; then
            local lock_age=$(($(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)))
            if [[ $lock_age -gt $LOCK_STALE ]]; then
                log "Removing stale lock (age: ${lock_age}s)"
                rm -f "$LOCK_FILE"
                break
            fi

            # Check if PID is still running
            local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log "Removing orphaned lock (PID $lock_pid not running)"
                rm -f "$LOCK_FILE"
                break
            fi
        fi

        # Wait and retry
        sleep 0.5
        waited=$((waited + 1))

        if [[ $waited -gt $((LOCK_TIMEOUT * 2)) ]]; then
            log "Timeout waiting for lock, giving up"
            exit 1
        fi
    done

    # Create lock with our PID
    echo $$ > "$LOCK_FILE"
    trap "rm -f '$LOCK_FILE'" EXIT
    log "Lock acquired by PID $$"
}

# Read all pending summaries sequentially
read_all_pending() {
    while true; do
        # Get oldest file in queue (sorted by timestamp in filename)
        local summary_file=$(ls -1 "$QUEUE_DIR"/*.txt 2>/dev/null | sort | head -1)

        [[ -z "$summary_file" ]] && break
        [[ ! -f "$summary_file" ]] && break

        # Extract session from filename for logging
        local filename=$(basename "$summary_file")
        local session=$(echo "$filename" | sed 's/^[0-9]*-\([^-]*\)-.*$/\1/' 2>/dev/null || echo "unknown")

        log "Reading: $filename (session: $session)"

        # Speak the content
        if [[ -s "$summary_file" ]]; then
            # Add small pause between readings
            say -v "$VOICE" -r "$RATE" -f "$summary_file"
            sleep 0.3
        fi

        # Remove after reading
        rm -f "$summary_file"
        log "Completed: $filename"
    done
}

# Main execution
acquire_lock
read_all_pending
log "Reader finished, releasing lock"
