#!/bin/bash
# orchestrator.sh - Main daemon that polls Telegram for commands
# Enhanced with voice message support via OpenAI Whisper

# Don't use set -e - we handle errors gracefully to keep the daemon running

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Lock file to prevent duplicate instances
LOCK_FILE="$SCRIPT_DIR/.orchestrator.lock"
if [[ -f "$LOCK_FILE" ]]; then
    OLD_PID=$(cat "$LOCK_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Orchestrator already running (PID $OLD_PID). Exiting."
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

# Source configs - .env.local for secrets, config.env for settings
[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

LOG_FILE="$SCRIPT_DIR/logs/orchestrator.log"
LAST_UPDATE_ID=0
SESSIONS_DIR="$SCRIPT_DIR/sessions"

mkdir -p "$SCRIPT_DIR/logs" "$SESSIONS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

get_status() {
    local status_msg=""
    local active_count=0
    local thinking_count=0
    local idle_count=0

    # Check tmux sessions (claude-N)
    for session_file in "$SESSIONS_DIR"/claude-*; do
        [[ -f "$session_file" ]] || continue
        [[ "$session_file" == *.pid ]] && continue

        session_name=$(basename "$session_file")
        if tmux has-session -t "$session_name" 2>/dev/null; then
            active_count=$((active_count + 1))

            # Get output - full for context, last 5 lines for current state
            local full_output=$(tmux capture-pane -t "$session_name" -p -S -15 2>/dev/null)
            local last_lines=$(echo "$full_output" | tail -8)

            # Detect state - check CURRENT state first (bottom of screen)
            local state_icon=""
            local state_label=""

            # Patterns for detection
            # Thinking: lines starting with spinner chars (✳ ✶ ✻ ·) followed by word and …
            local think_pattern="^[✳✶✻·] [A-Z][a-z]+…"
            # Done: completion indicators
            local done_pattern="^✻ (Cogitated|Worked|Baked|Crunched|Churned) for"

            # Detect state - priority order
            if echo "$full_output" | tail -12 | grep -qE "$think_pattern"; then
                # Currently thinking/processing (spinner visible)
                state_icon="⏳"
                state_label="thinking"
                thinking_count=$((thinking_count + 1))
            elif echo "$full_output" | tail -15 | grep -qE "$done_pattern"; then
                # Completed work
                state_icon="🟢"
                state_label="idle"
                idle_count=$((idle_count + 1))
            elif echo "$last_lines" | grep -q "bypass permissions"; then
                state_icon="🟢"
                state_label="idle"
                idle_count=$((idle_count + 1))
            else
                state_icon="💬"
                state_label="ready"
                idle_count=$((idle_count + 1))
            fi

            # Special handling for coordinator
            if [[ "$session_name" == "claude-0" ]]; then
                state_icon="🎯"
            fi

            # Get context: what's the session doing?
            local context=""
            # Check for thinking time
            local think_time=$(echo "$full_output" | grep -oE "thought for [0-9]+s|[0-9]+m [0-9]+s" | tail -1)
            if [[ -n "$think_time" ]]; then
                context="($think_time)"
            fi
            # Check for token count
            local tokens=$(echo "$full_output" | grep -oE "↓ [0-9.]+k tokens" | tail -1)
            if [[ -n "$tokens" ]]; then
                context="$context $tokens"
            fi

            status_msg+="$state_icon <b>$session_name</b> <i>$state_label</i> $context
"
        else
            status_msg+="🔴 <b>$session_name</b> <i>stopped</i>
"
            rm -f "$session_file" "$session_file.monitor.pid"
        fi
    done

    # Check cursor sessions (claude-cursor-N)
    for session_file in "$SESSIONS_DIR"/claude-cursor-*; do
        [[ -f "$session_file" ]] || continue
        [[ "$session_file" == *.queue ]] && continue

        session_name=$(basename "$session_file")
        active_count=$((active_count + 1))

        # Check if there are pending messages
        local queue_file="$SESSIONS_DIR/${session_name}.queue"
        local pending=""
        if [[ -f "$queue_file" ]]; then
            pending=" 📬"
        fi

        status_msg+="💻 <b>$session_name</b> (cursor)$pending

"
    done

    if [[ -z "$status_msg" ]]; then
        status_msg="No active sessions. Use /new to start one."
    else
        local summary="📊 <b>$active_count sessions</b>"
        [[ $thinking_count -gt 0 ]] && summary+=" · $thinking_count thinking"
        [[ $idle_count -gt 0 ]] && summary+=" · $idle_count idle"
        status_msg="$summary

$status_msg
<i>🟢idle ⏳thinking 🔄working 📝has input 🎯coordinator</i>"
    fi

    echo "$status_msg"
}

inject_input() {
    local session="$1"
    local input="$2"
    local from_telegram="${3:-false}"

    # Handle claude-cursor-N sessions (non-tmux, running in Cursor/terminal)
    if [[ "$session" == claude-cursor-* ]]; then
        local session_file="$SESSIONS_DIR/$session"
        if [[ ! -f "$session_file" ]]; then
            log "Cursor session $session not found"
            "$SCRIPT_DIR/notify.sh" "error" "$session" "Session not found or closed"
            return 1
        fi

        # Append summary instruction
        if [[ "$from_telegram" == "true" ]]; then
            input="$input
<tg>send-summary.sh</tg>"
        fi

        # Write to queue file for the cursor session
        local queue_file="$SESSIONS_DIR/${session}.queue"
        echo "---[$(date '+%H:%M:%S')]---" >> "$queue_file"
        echo "$input" >> "$queue_file"

        # Skip macOS notification - user doesn't want popups

        log "Queued for $session: ${input:0:100}..."
        "$SCRIPT_DIR/notify.sh" "update" "$session" "Message queued. Check queue with:
cat ~/.claude/telegram-orchestrator/sessions/${session}.queue"
        return 0
    fi

    # Handle tmux sessions (claude-N)
    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "Session $session not found"
        "$SCRIPT_DIR/notify.sh" "error" "$session" "Session not found"
        return 1
    fi

    # Append summary instruction for Telegram messages (subtle, at end)
    if [[ "$from_telegram" == "true" ]]; then
        input="$input
<tg>send-summary.sh</tg>"
    fi

    # Use temp file + load-buffer for reliable long message injection
    local tmpfile=$(mktemp)
    printf '%s' "$input" > "$tmpfile"
    tmux load-buffer -b telegram_msg "$tmpfile"
    tmux paste-buffer -b telegram_msg -t "$session"
    tmux delete-buffer -b telegram_msg 2>/dev/null || true
    rm -f "$tmpfile"

    # Press Enter (use hex code 0d for reliability)
    sleep 0.5
    tmux send-keys -t "$session" -H 0d

    log "Injected to $session: ${input:0:100}..."
}

kill_session() {
    local session="$1"

    if tmux has-session -t "$session" 2>/dev/null; then
        tmux send-keys -t "$session" "/exit"
        tmux send-keys -t "$session" -H 0d
        sleep 2
        tmux kill-session -t "$session" 2>/dev/null || true
        log "Killed session $session"
        "$SCRIPT_DIR/notify.sh" "complete" "$session" "Session killed by user"
    fi

    rm -f "$SESSIONS_DIR/$session" "$SESSIONS_DIR/$session.monitor.pid"
}

# Process voice message - transcribe and return text
process_voice() {
    local file_id="$1"
    local message_id="$2"
    local chat_id="$3"
    local target_session="$4"  # Optional: from reply routing

    log "Processing voice message: $file_id (target: ${target_session:-auto})"

    # Call transcription script
    transcription=$("$SCRIPT_DIR/src/voice/transcribe.sh" "$file_id" "$message_id" 2>&1)

    if [[ "$transcription" == ERROR* ]]; then
        log "Voice transcription failed: $transcription"
        "$SCRIPT_DIR/notify.sh" "error" "system" "Voice transcription failed: $transcription"
        return 1
    fi

    log "Transcribed: $transcription"

    # Process the transcribed text as a regular message, with reply routing if provided
    process_message "$transcription" "$chat_id" "$target_session"
}

# Process photo message - download and inject path to Claude
process_photo() {
    local file_id="$1"
    local message_id="$2"
    local chat_id="$3"
    local target_session="$4"  # Optional: from reply routing
    local caption="$5"         # Optional: photo caption

    log "Processing photo: $file_id (target: ${target_session:-auto})"

    # Download the image
    local image_path=$("$SCRIPT_DIR/src/image/download.sh" "$file_id" "$message_id" 2>&1)

    if [[ "$image_path" == ERROR* ]]; then
        log "Photo download failed: $image_path"
        "$SCRIPT_DIR/notify.sh" "error" "system" "Photo download failed: $image_path"
        return 1
    fi

    log "Downloaded image: $image_path"

    # Build message for Claude
    local message="[Image attached: $image_path]

Please view this image using the Read tool and analyze it."

    if [[ -n "$caption" ]]; then
        message="$caption

[Image attached: $image_path]"
    fi

    # Use target_session if provided, otherwise use coordinator
    local session_to_use="$target_session"
    if [[ -z "$session_to_use" ]]; then
        session_to_use="claude-0"

        # Ensure coordinator is running
        if ! tmux has-session -t "claude-0" 2>/dev/null; then
            log "Coordinator not running, starting..."
            "$SCRIPT_DIR/start-claude.sh" --coordinator
            sleep 3
        fi
    fi

    inject_input "$session_to_use" "$message" "true"
    "$SCRIPT_DIR/notify.sh" "update" "$session_to_use" "📷 Image received and sent to $session_to_use"
}

process_message() {
    local message="$1"
    local chat_id="$2"
    local target_session="$3"  # Optional: specific session from reply routing

    if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        sed -i '' "s/TELEGRAM_CHAT_ID=\"\"/TELEGRAM_CHAT_ID=\"$chat_id\"/" "$SCRIPT_DIR/config.env"
        source "$SCRIPT_DIR/config.env"
        log "Auto-configured chat ID: $chat_id"
    fi

    if [[ "$message" == /status* ]]; then
        status_result=$(get_status)
        "$SCRIPT_DIR/notify.sh" "update" "status" "$status_result"

    elif [[ "$message" == /new* ]]; then
        initial_prompt="${message#/new}"
        initial_prompt="${initial_prompt# }"
        "$SCRIPT_DIR/start-claude.sh" "$initial_prompt"

    elif [[ "$message" == /tts* ]]; then
        if [[ -f "$HOME/.claude/tts/enabled" ]]; then
            rm -f "$HOME/.claude/tts/enabled"
            "$SCRIPT_DIR/notify.sh" "update" "system" "TTS disabled"
        else
            mkdir -p "$HOME/.claude/tts"
            touch "$HOME/.claude/tts/enabled"
            "$SCRIPT_DIR/notify.sh" "update" "system" "TTS enabled"
        fi

    elif [[ "$message" == /kill* ]]; then
        session_num="${message#/kill}"
        session_num="${session_num# }"
        if [[ -n "$session_num" ]]; then
            kill_session "claude-$session_num"
        else
            "$SCRIPT_DIR/notify.sh" "error" "system" "Usage: /kill <number>"
        fi

    elif [[ "$message" == /resume* ]]; then
        query="${message#/resume}"
        query="${query# }"
        if [[ -z "$query" ]]; then
            "$SCRIPT_DIR/notify.sh" "error" "system" "Usage: /resume <description>
Example: /resume the auth bug fix"
        else
            "$SCRIPT_DIR/notify.sh" "update" "system" "Searching for session: $query..."
            session_id=$("$SCRIPT_DIR/find-session.sh" "$query" 2>/dev/null)
            if [[ -n "$session_id" ]]; then
                log "Found session to resume: $session_id"
                "$SCRIPT_DIR/start-claude.sh" --resume "$session_id" --query "$query"
            else
                "$SCRIPT_DIR/notify.sh" "error" "system" "No matching session found for: $query"
            fi
        fi

    elif [[ "$message" == /watchdog* ]]; then
        watchdog_args="${message#/watchdog}"
        watchdog_args="${watchdog_args# }"
        if [[ -z "$watchdog_args" ]]; then
            # No args = status
            result=$("$SCRIPT_DIR/watchdog.sh" status 2>&1)
            "$SCRIPT_DIR/notify.sh" "update" "watchdog" "$result"
        else
            # Pass args to control script
            result=$("$SCRIPT_DIR/watchdog.sh" $watchdog_args 2>&1)
            "$SCRIPT_DIR/notify.sh" "update" "watchdog" "$result"
        fi

    else
        # Use target_session if provided (from reply routing), otherwise use coordinator
        local session_to_use="$target_session"
        if [[ -z "$session_to_use" ]]; then
            # Default to coordinator (claude-0)
            session_to_use="claude-0"

            # Ensure coordinator is running
            if ! tmux has-session -t "claude-0" 2>/dev/null; then
                log "Coordinator not running, starting..."
                "$SCRIPT_DIR/start-claude.sh" --coordinator
                sleep 3
            fi
        fi

        if [[ "$session_to_use" == claude-cursor-* ]]; then
            # Cursor session - inject_input handles the queue
            inject_input "$session_to_use" "$message" "true"
        elif tmux has-session -t "$session_to_use" 2>/dev/null; then
            # Tmux session
            inject_input "$session_to_use" "$message" "true"
        else
            "$SCRIPT_DIR/notify.sh" "error" "system" "Session $session_to_use not found."
        fi
    fi
}

# Ensure coordinator (claude-0) is running
ensure_coordinator() {
    if ! tmux has-session -t "claude-0" 2>/dev/null; then
        log "Starting coordinator claude-0..."
        "$SCRIPT_DIR/start-claude.sh" --coordinator
        sleep 3  # Give it time to start
    fi
}

# Main loop
log "Orchestrator starting..."
log "Polling Telegram every ${POLL_INTERVAL}s"

# Start coordinator on boot
ensure_coordinator

while true; do
    response=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((LAST_UPDATE_ID + 1))&timeout=30" 2>/dev/null || echo '{"ok":false}')

    if [[ $(echo "$response" | jq -r '.ok') == "true" ]]; then
        updates=$(echo "$response" | jq -c '.result[]' 2>/dev/null || echo "")

        while IFS= read -r update; do
            [[ -z "$update" ]] && continue

            update_id=$(echo "$update" | jq -r '.update_id')
            chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
            message_id=$(echo "$update" | jq -r '.message.message_id // empty')

            # Extract reply context FIRST (applies to both voice and text)
            reply_to_text=$(echo "$update" | jq -r '.message.reply_to_message.text // empty')
            target_session=""
            if [[ -n "$reply_to_text" ]]; then
                # Match [claude-N] for tmux sessions
                if [[ "$reply_to_text" =~ \[claude-([0-9]+)\] ]]; then
                    target_session="claude-${BASH_REMATCH[1]}"
                    log "Reply routing detected: $target_session"
                # Match [claude-cursor-N] for cursor sessions
                elif [[ "$reply_to_text" =~ \[claude-cursor-([0-9]+)\] ]]; then
                    target_session="claude-cursor-${BASH_REMATCH[1]}"
                    log "Reply routing detected: $target_session"
                fi
            fi

            # Check for voice message
            voice_file_id=$(echo "$update" | jq -r '.message.voice.file_id // empty')

            if [[ -n "$voice_file_id" && -n "$chat_id" ]]; then
                log "Received voice message from $chat_id (target: ${target_session:-auto})"
                process_voice "$voice_file_id" "$message_id" "$chat_id" "$target_session"
                LAST_UPDATE_ID=$update_id
                continue
            fi

            # Check for photo message (get largest size - last in array)
            photo_file_id=$(echo "$update" | jq -r '.message.photo[-1].file_id // empty')
            photo_caption=$(echo "$update" | jq -r '.message.caption // empty')

            if [[ -n "$photo_file_id" && -n "$chat_id" ]]; then
                log "Received photo from $chat_id (target: ${target_session:-auto})"
                process_photo "$photo_file_id" "$message_id" "$chat_id" "$target_session" "$photo_caption"
                LAST_UPDATE_ID=$update_id
                continue
            fi

            # Check for text message
            message_text=$(echo "$update" | jq -r '.message.text // empty')

            if [[ -n "$message_text" && -n "$chat_id" ]]; then
                if [[ -n "$target_session" ]]; then
                    log "Reply to $target_session: $message_text"
                    inject_input "$target_session" "$message_text" "true"
                else
                    log "Received: $message_text from $chat_id"
                    process_message "$message_text" "$chat_id"
                fi
            fi

            LAST_UPDATE_ID=$update_id
        done <<< "$updates"
    else
        log "Telegram API error, retrying..."
    fi

    sleep "$POLL_INTERVAL"
done
