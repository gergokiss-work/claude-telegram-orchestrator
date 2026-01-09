#!/bin/bash
# api-server.sh - HTTP API server for n8n to communicate with
# Runs on Mac, receives commands from n8n, sends output back

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

PORT="${API_PORT:-8765}"
LOG_FILE="$SCRIPT_DIR/logs/api-server.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Send response to n8n webhook
notify_n8n() {
    local type="$1"
    local session="$2"
    local message="$3"
    local reply_to="$4"

    curl -s -X POST "${N8N_BASE_URL}${N8N_NOTIFY_WEBHOOK}" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"$type\",
            \"session\": \"$session\",
            \"message\": $(echo "$message" | jq -Rs .),
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"reply_to_message_id\": $reply_to
        }" >> "$LOG_FILE" 2>&1
}

# Handle incoming requests
handle_request() {
    local request="$1"

    # Parse JSON body
    local action=$(echo "$request" | jq -r '.action // empty')
    local text=$(echo "$request" | jq -r '.text // empty')
    local prompt=$(echo "$request" | jq -r '.prompt // empty')
    local session=$(echo "$request" | jq -r '.session // empty')
    local message_id=$(echo "$request" | jq -r '.message_id // "null"')

    log "Received: action=$action session=$session"

    case "$action" in
        new)
            # Create new session
            local session_num=$(ls -1 "$SCRIPT_DIR/sessions/" 2>/dev/null | grep -c "claude-")
            session_num=$((session_num + 1))
            local new_session="claude-$session_num"

            # Start Claude in tmux
            "$SCRIPT_DIR/start-claude.sh" "$new_session" "$prompt" &

            # Store message_id for reply routing
            echo "$message_id" > "$SCRIPT_DIR/sessions/$new_session.msg_id"

            log "Created session $new_session"
            echo "{\"status\": \"ok\", \"session\": \"$new_session\"}"

            # Notify
            notify_n8n "new" "$new_session" "Session started" "$message_id"
            ;;

        status)
            # List sessions
            local sessions=""
            for f in "$SCRIPT_DIR/sessions/claude-"*; do
                if [[ -f "$f" ]] && [[ ! "$f" =~ \.pid$ ]] && [[ ! "$f" =~ \.msg_id$ ]]; then
                    local name=$(basename "$f")
                    if tmux has-session -t "$name" 2>/dev/null; then
                        sessions+="$name (active)\n"
                    fi
                fi
            done

            if [[ -z "$sessions" ]]; then
                sessions="No active sessions"
            fi

            log "Status requested"
            echo "{\"status\": \"ok\", \"sessions\": \"$sessions\"}"
            ;;

        message)
            # Route message to session
            local target="$session"

            # If no session specified, use most recent
            if [[ -z "$target" ]]; then
                target=$(ls -t "$SCRIPT_DIR/sessions/claude-"* 2>/dev/null | grep -v "\.pid$" | grep -v "\.msg_id$" | head -1 | xargs basename)
            fi

            if [[ -n "$target" ]] && tmux has-session -t "$target" 2>/dev/null; then
                # Inject message
                tmux send-keys -t "$target" "$text" Enter
                log "Injected to $target: $text"

                # Store message_id for reply
                echo "$message_id" > "$SCRIPT_DIR/sessions/$target.msg_id"

                echo "{\"status\": \"ok\", \"session\": \"$target\"}"
            else
                log "No valid session for message"
                echo "{\"status\": \"error\", \"message\": \"No active session\"}"
            fi
            ;;

        kill)
            if [[ -n "$session" ]] && tmux has-session -t "$session" 2>/dev/null; then
                tmux kill-session -t "$session"
                rm -f "$SCRIPT_DIR/sessions/$session"*
                log "Killed session $session"
                echo "{\"status\": \"ok\"}"
            else
                echo "{\"status\": \"error\", \"message\": \"Session not found\"}"
            fi
            ;;

        *)
            echo "{\"status\": \"error\", \"message\": \"Unknown action: $action\"}"
            ;;
    esac
}

# Simple HTTP server using netcat
log "Starting API server on port $PORT"
echo "API server starting on port $PORT..."

while true; do
    # Read request
    {
        read -r request_line

        # Read headers until empty line
        content_length=0
        while read -r header; do
            header=$(echo "$header" | tr -d '\r')
            [[ -z "$header" ]] && break
            if [[ "$header" =~ ^Content-Length:\ ([0-9]+) ]]; then
                content_length="${BASH_REMATCH[1]}"
            fi
        done

        # Read body
        body=""
        if [[ $content_length -gt 0 ]]; then
            body=$(head -c "$content_length")
        fi

        # Handle request
        if [[ "$request_line" =~ ^POST\ /api/command ]]; then
            response=$(handle_request "$body")
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${#response}\r\n\r\n$response"
        elif [[ "$request_line" =~ ^GET\ /health ]]; then
            response='{"status":"ok"}'
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${#response}\r\n\r\n$response"
        else
            response='{"error":"Not found"}'
            echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ${#response}\r\n\r\n$response"
        fi
    } < <(nc -l "$PORT" 2>/dev/null) | nc -l "$PORT" 2>/dev/null &

    wait
done
