#!/bin/bash
# start-claude.sh - Start a new Claude Code session in tmux
# Usage: start-claude.sh [initial_prompt] [working_dir]
#        start-claude.sh --resume <session-id> [working_dir]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Parse arguments
RESUME_SESSION=""
RESUME_QUERY=""
INITIAL_PROMPT=""
WORKING_DIR="$HOME"
COORDINATOR_MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume)
            RESUME_SESSION="$2"
            shift 2
            ;;
        --query)
            RESUME_QUERY="$2"
            shift 2
            ;;
        --coordinator)
            COORDINATOR_MODE="true"
            shift
            ;;
        *)
            if [[ -z "$INITIAL_PROMPT" ]]; then
                INITIAL_PROMPT="$1"
            else
                WORKING_DIR="$1"
            fi
            shift
            ;;
    esac
done

SESSIONS_DIR="$SCRIPT_DIR/sessions"
mkdir -p "$SESSIONS_DIR"

# Determine session name
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    # Coordinator is always claude-0
    SESSION_NAME="claude-0"

    # Check if already running
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Coordinator claude-0 already running"
        exit 0
    fi
else
    # Find next available session number (start from 1, 0 is reserved for coordinator)
    SESSION_NUM=1
    while [[ -f "$SESSIONS_DIR/claude-$SESSION_NUM" ]] && tmux has-session -t "claude-$SESSION_NUM" 2>/dev/null; do
        SESSION_NUM=$((SESSION_NUM + 1))
        if [[ $SESSION_NUM -gt $MAX_SESSIONS ]]; then
            echo "Error: Maximum sessions ($MAX_SESSIONS) reached"
            "$SCRIPT_DIR/notify.sh" "error" "system" "Max sessions reached ($MAX_SESSIONS)"
            exit 1
        fi
    done
    SESSION_NAME="claude-$SESSION_NUM"
fi

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -c "$WORKING_DIR"

# Start Claude - coordinator, resuming, or fresh
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    # Start coordinator with special system prompt
    COORDINATOR_MD="$SCRIPT_DIR/coordinator-claude.md"
    tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $COORDINATOR_MD)\""
    tmux send-keys -t "$SESSION_NAME" -H 0d
elif [[ -n "$RESUME_SESSION" ]]; then
    # Resume existing session
    tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions --resume $RESUME_SESSION"
    tmux send-keys -t "$SESSION_NAME" -H 0d
else
    # Start fresh Claude
    tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions"
    tmux send-keys -t "$SESSION_NAME" -H 0d

    # Send initial prompt if provided
    if [[ -n "$INITIAL_PROMPT" ]]; then
        sleep 5
        tmux send-keys -t "$SESSION_NAME" "$INITIAL_PROMPT"
        tmux send-keys -t "$SESSION_NAME" -H 0d
    fi
fi

# Record session info
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR",
  "role": "coordinator"
}
EOF
elif [[ -n "$RESUME_SESSION" ]]; then
    cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR",
  "resumed_from": "$RESUME_SESSION",
  "resume_query": "$RESUME_QUERY"
}
EOF
else
    cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR"
}
EOF
fi

# Session monitor disabled - using queue-based summaries instead
# nohup "$SCRIPT_DIR/session-monitor.sh" "$SESSION_NAME" >> "$SCRIPT_DIR/logs/monitor-$SESSION_NAME.log" 2>&1 &
# echo $! > "$SESSIONS_DIR/$SESSION_NAME.monitor.pid"

# Notify
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "🎯 Coordinator started
Ready to receive messages
Use: tmux attach -t $SESSION_NAME"
    echo "Started coordinator $SESSION_NAME"
elif [[ -n "$RESUME_SESSION" ]]; then
    if [[ -n "$RESUME_QUERY" ]]; then
        "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "🔄 Resumed: \"$RESUME_QUERY\"
Session: ${RESUME_SESSION:0:8}...
Use: tmux attach -t $SESSION_NAME"
    else
        "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "🔄 Resumed session ${RESUME_SESSION:0:8}...
Use: tmux attach -t $SESSION_NAME"
    fi
    echo "Started $SESSION_NAME (resumed from $RESUME_SESSION)"
else
    "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "Started in $WORKING_DIR
Use: tmux attach -t $SESSION_NAME"
    echo "Started $SESSION_NAME"
fi
