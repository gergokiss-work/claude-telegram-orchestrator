#!/bin/bash
# orchestrator.sh - Main daemon that polls Telegram for commands
# Enhanced with voice message support via OpenAI Whisper

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
    local status=""
    for session_file in "$SESSIONS_DIR"/claude-*; do
        [[ -f "$session_file" ]] || continue
        [[ "$session_file" == *.pid ]] && continue

        session_name=$(basename "$session_file")
        if tmux has-session -t "$session_name" 2>/dev/null; then
            last_output=$(tmux capture-pane -t "$session_name" -p -S -5 2>/dev/null | grep -v '^$' | tail -3)
            status+="🟢 $session_name: active
$last_output

"
        else
            status+="🔴 $session_name: stopped
"
            rm -f "$session_file" "$session_file.monitor.pid"
        fi
    done

    if [[ -z "$status" ]]; then
        status="No active sessions. Use /new to start one."
    fi

    echo "$status"
}

inject_input() {
    local session="$1"
    local input="$2"
    local from_telegram="${3:-false}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "Session $session not found"
        "$SCRIPT_DIR/notify.sh" "error" "$session" "Session not found"
        return 1
    fi

    # Append summary instruction for Telegram messages
    if [[ "$from_telegram" == "true" ]]; then
        input="$input

[TELEGRAM] When done, send summary: ~/.claude/telegram-orchestrator/send-summary.sh \"your summary here\""
    fi

    # Use temp file + load-buffer for reliable long message injection
    local tmpfile=$(mktemp)
    printf '%s' "$input" > "$tmpfile"
    tmux load-buffer -b telegram_msg "$tmpfile"
    tmux paste-buffer -b telegram_msg -t "$session"
    tmux delete-buffer -b telegram_msg 2>/dev/null || true
    rm -f "$tmpfile"

    # Press Enter
    sleep 0.2
    tmux send-keys -t "$session" Enter

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

    log "Processing voice message: $file_id"

    # Call transcription script
    transcription=$("$SCRIPT_DIR/src/voice/transcribe.sh" "$file_id" "$message_id" 2>&1)

    if [[ "$transcription" == ERROR* ]]; then
        log "Voice transcription failed: $transcription"
        "$SCRIPT_DIR/notify.sh" "error" "system" "Voice transcription failed: $transcription"
        return 1
    fi

    log "Transcribed: $transcription"

    # Process the transcribed text as a regular message
    process_message "$transcription" "$chat_id"
}

process_message() {
    local message="$1"
    local chat_id="$2"

    if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        sed -i '' "s/TELEGRAM_CHAT_ID=\"\"/TELEGRAM_CHAT_ID=\"$chat_id\"/" "$SCRIPT_DIR/config.env"
        source "$SCRIPT_DIR/config.env"
        log "Auto-configured chat ID: $chat_id"
    fi

    if [[ "$message" == /status* ]]; then
        status=$(get_status)
        "$SCRIPT_DIR/notify.sh" "update" "status" "$status"

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

    else
        latest_session=$(ls -t "$SESSIONS_DIR"/claude-* 2>/dev/null | grep -v '.pid' | head -1 | xargs basename 2>/dev/null || echo "")
        if [[ -n "$latest_session" ]] && tmux has-session -t "$latest_session" 2>/dev/null; then
            inject_input "$latest_session" "$message" "true"
        else
            "$SCRIPT_DIR/notify.sh" "error" "system" "No active session. Use /new to start one."
        fi
    fi
}

# Main loop
log "Orchestrator starting..."
log "Polling Telegram every ${POLL_INTERVAL}s"

while true; do
    response=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((LAST_UPDATE_ID + 1))&timeout=30" 2>/dev/null || echo '{"ok":false}')

    if [[ $(echo "$response" | jq -r '.ok') == "true" ]]; then
        updates=$(echo "$response" | jq -c '.result[]' 2>/dev/null || echo "")

        while IFS= read -r update; do
            [[ -z "$update" ]] && continue

            update_id=$(echo "$update" | jq -r '.update_id')
            chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
            message_id=$(echo "$update" | jq -r '.message.message_id // empty')

            # Check for voice message first
            voice_file_id=$(echo "$update" | jq -r '.message.voice.file_id // empty')

            if [[ -n "$voice_file_id" && -n "$chat_id" ]]; then
                log "Received voice message from $chat_id"
                process_voice "$voice_file_id" "$message_id" "$chat_id"
                LAST_UPDATE_ID=$update_id
                continue
            fi

            # Check for text message
            message_text=$(echo "$update" | jq -r '.message.text // empty')
            reply_to_text=$(echo "$update" | jq -r '.message.reply_to_message.text // empty')

            if [[ -n "$message_text" && -n "$chat_id" ]]; then
                if [[ -n "$reply_to_text" ]]; then
                    if [[ "$reply_to_text" =~ \[claude-([0-9]+)\] ]]; then
                        session_num="${BASH_REMATCH[1]}"
                        log "Reply detected for claude-$session_num: $message_text"
                        inject_input "claude-$session_num" "$message_text" "true"
                        LAST_UPDATE_ID=$update_id
                        continue
                    fi
                fi

                log "Received: $message_text from $chat_id"
                process_message "$message_text" "$chat_id"
            fi

            LAST_UPDATE_ID=$update_id
        done <<< "$updates"
    else
        log "Telegram API error, retrying..."
    fi

    sleep "$POLL_INTERVAL"
done
