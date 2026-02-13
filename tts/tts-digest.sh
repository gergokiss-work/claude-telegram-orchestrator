#!/bin/bash
# TTS Digest Mode - Coordinator batch reader
# Collects pending TTS messages, groups by priority, reads as single coherent block
#
# Usage: tts-digest.sh              # Wait 10s for stragglers, then read
#        tts-digest.sh --no-wait    # Read immediately
#        tts-digest.sh --dry-run    # Show what would be read without speaking

TTS_DIR="$HOME/.claude/tts"
QUEUE_DIR="$TTS_DIR/queue"
ENABLED_FILE="$TTS_DIR/enabled"
LOCK_FILE="$TTS_DIR/reading.lock"
LOG_FILE="$TTS_DIR/reader.log"

VOICE="${CLAUDE_TTS_VOICE:-Daniel}"
RATE="${CLAUDE_TTS_RATE:-200}"
WAIT_SECONDS=10
DRY_RUN=false

log() {
    echo "[$(date '+%H:%M:%S')] [digest] $1" >> "$LOG_FILE"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-wait) WAIT_SECONDS=0; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) shift ;;
    esac
done

# Check if TTS is enabled
if [[ ! -f "$ENABLED_FILE" ]]; then
    echo "TTS not enabled"
    exit 0
fi

# Check queue exists
if [[ ! -d "$QUEUE_DIR" ]]; then
    echo "No TTS queue directory"
    exit 0
fi

# Count pending messages
count_pending() {
    ls -1 "$QUEUE_DIR"/*.txt 2>/dev/null | wc -l | tr -d ' '
}

INITIAL_COUNT=$(count_pending)
if [[ "$INITIAL_COUNT" -eq 0 ]]; then
    echo "No pending TTS messages"
    exit 0
fi

# Wait for stragglers (agents finishing around the same time)
if [[ "$WAIT_SECONDS" -gt 0 ]]; then
    log "Digest: waiting ${WAIT_SECONDS}s for stragglers ($INITIAL_COUNT messages queued)"
    sleep "$WAIT_SECONDS"
fi

FINAL_COUNT=$(count_pending)
log "Digest: processing $FINAL_COUNT messages"

# Acquire lock (same as tts-reader.sh)
acquire_lock() {
    local waited=0
    while [[ -f "$LOCK_FILE" ]]; do
        if [[ -f "$LOCK_FILE" ]]; then
            local lock_age=$(($(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)))
            if [[ $lock_age -gt 120 ]]; then
                rm -f "$LOCK_FILE"
                break
            fi
            local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                rm -f "$LOCK_FILE"
                break
            fi
        fi
        sleep 0.5
        waited=$((waited + 1))
        if [[ $waited -gt 120 ]]; then
            log "Digest: lock timeout"
            exit 1
        fi
    done
    echo $$ > "$LOCK_FILE"
    trap "rm -f '$LOCK_FILE'" EXIT
}

# Collect and group all messages
build_digest() {
    local urgent_msgs=()
    local important_msgs=()
    local routine_msgs=()

    # Read all files sorted by priority then timestamp
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$file" ]] && continue

        local filename=$(basename "$file")
        local priority=$(echo "$filename" | cut -d'-' -f1)
        local session=$(echo "$filename" | cut -d'-' -f3)
        local content
        content=$(cat "$file")

        case "$priority" in
            1) urgent_msgs+=("${session}: ${content}") ;;
            2) important_msgs+=("${session}: ${content}") ;;
            *)  routine_msgs+=("${session}: ${content}") ;;
        esac
    done < <(ls -1 "$QUEUE_DIR"/*.txt 2>/dev/null | sort)

    local total=$(( ${#urgent_msgs[@]} + ${#important_msgs[@]} + ${#routine_msgs[@]} ))

    # Build natural speech digest
    local digest=""

    if [[ $total -eq 1 ]]; then
        digest="One agent update. "
    else
        digest="${total} agent updates. "
    fi

    if [[ ${#urgent_msgs[@]} -gt 0 ]]; then
        digest+="Urgent: "
        for msg in "${urgent_msgs[@]}"; do
            digest+="${msg}. "
        done
    fi

    if [[ ${#important_msgs[@]} -gt 0 ]]; then
        if [[ ${#urgent_msgs[@]} -gt 0 ]]; then
            digest+="Next, "
        fi
        for msg in "${important_msgs[@]}"; do
            digest+="${msg}. "
        done
    fi

    if [[ ${#routine_msgs[@]} -gt 0 ]]; then
        if [[ ${#urgent_msgs[@]} -gt 0 ]] || [[ ${#important_msgs[@]} -gt 0 ]]; then
            digest+="Also, "
        fi
        for msg in "${routine_msgs[@]}"; do
            digest+="${msg}. "
        done
    fi

    echo "$digest"
}

# Build the digest text
DIGEST_TEXT=$(build_digest)

if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== TTS Digest Preview ==="
    echo "$DIGEST_TEXT"
    echo "=========================="
    echo "($FINAL_COUNT messages would be consumed)"
    exit 0
fi

# Acquire lock and speak
acquire_lock
log "Digest: speaking $FINAL_COUNT messages as one block"

# Speak the digest
AUDIO_FILE="/tmp/tts-digest-$$.aiff"
say -v "$VOICE" -r "$RATE" -o "$AUDIO_FILE" "$DIGEST_TEXT"
afplay "$AUDIO_FILE"
rm -f "$AUDIO_FILE"

# Remove all consumed queue files
rm -f "$QUEUE_DIR"/*.txt

sleep 0.5
log "Digest: complete, $FINAL_COUNT messages consumed"
echo "Digest complete: $FINAL_COUNT messages read"
