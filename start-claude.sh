#!/bin/bash
# start-claude.sh - Start a new Claude Code session in tmux

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

INITIAL_PROMPT="${1:-}"
WORKING_DIR="${2:-$HOME}"

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

# Start Claude with dangerous mode
tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions"
tmux send-keys -t "$SESSION_NAME" -H 0d

# Send initial prompt if provided
if [[ -n "$INITIAL_PROMPT" ]]; then
    sleep 5
    tmux send-keys -t "$SESSION_NAME" "$INITIAL_PROMPT"
    tmux send-keys -t "$SESSION_NAME" -H 0d
fi

# Record session info
cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR"
}
EOF

# Start session monitor
nohup "$SCRIPT_DIR/session-monitor.sh" "$SESSION_NAME" >> "$SCRIPT_DIR/logs/monitor-$SESSION_NAME.log" 2>&1 &
echo $! > "$SESSIONS_DIR/$SESSION_NAME.monitor.pid"

# Notify
"$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "Started in $WORKING_DIR
Use: tmux attach -t $SESSION_NAME"

# Try to open in Cursor (macOS)
if [[ "$(uname)" == "Darwin" ]]; then
    osascript << EOF &
tell application "Cursor"
    activate
    delay 0.5
end tell
tell application "System Events"
    tell process "Cursor"
        keystroke "\`" using {control down}
        delay 0.5
        keystroke "tmux attach -t $SESSION_NAME"
        delay 0.2
        key code 36
    end tell
end tell
EOF
fi

echo "Started $SESSION_NAME"
