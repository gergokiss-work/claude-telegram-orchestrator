#!/bin/bash
# start-claude.sh - Start a new Claude Code session in tmux
# Usage: start-claude.sh [initial_prompt] [working_dir]
#        start-claude.sh --resume <session-id> [working_dir]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Parse arguments
RESUME_SESSION=""
INITIAL_PROMPT=""
WORKING_DIR="$HOME"

if [[ "$1" == "--resume" ]]; then
    RESUME_SESSION="$2"
    WORKING_DIR="${3:-$HOME}"
else
    INITIAL_PROMPT="${1:-}"
    WORKING_DIR="${2:-$HOME}"
fi

SESSIONS_DIR="$SCRIPT_DIR/sessions"
mkdir -p "$SESSIONS_DIR"

# Find next available session number
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

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -c "$WORKING_DIR"

# Start Claude - either resuming or fresh
if [[ -n "$RESUME_SESSION" ]]; then
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
if [[ -n "$RESUME_SESSION" ]]; then
    cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR",
  "resumed_from": "$RESUME_SESSION"
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
if [[ -n "$RESUME_SESSION" ]]; then
    "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "Resumed session ${RESUME_SESSION:0:8}...
Use: tmux attach -t $SESSION_NAME"
    echo "Started $SESSION_NAME (resumed from $RESUME_SESSION)"
else
    "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "Started in $WORKING_DIR
Use: tmux attach -t $SESSION_NAME"
    echo "Started $SESSION_NAME"
fi
