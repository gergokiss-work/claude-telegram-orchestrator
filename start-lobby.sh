#!/bin/bash
# start-lobby.sh - Start/attach to Clawdbot monitoring session
# Creates a tmux session "lobby" for Clawdbot CLI access and log monitoring

SESSION_NAME="lobby"
CLAWDBOT_LOG="$HOME/.clawdbot/logs/gateway.log"

# Check if session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session '$SESSION_NAME' already exists"
    if [[ "$1" == "--attach" ]]; then
        tmux attach -t "$SESSION_NAME"
    fi
    exit 0
fi

# Create new session with log tail
echo "Creating Clawdbot monitoring session: $SESSION_NAME"
tmux new-session -d -s "$SESSION_NAME" -n "logs" "tail -f $CLAWDBOT_LOG"

# Add a second window for interactive clawdbot CLI
tmux new-window -t "$SESSION_NAME" -n "cli" "zsh"
tmux send-keys -t "$SESSION_NAME:cli" "echo '🦞 Clawdbot CLI ready. Try: clawdbot status, clawdbot logs, clawdbot dashboard'" Enter

# Select the logs window by default
tmux select-window -t "$SESSION_NAME:logs"

echo "✅ Session '$SESSION_NAME' created with:"
echo "   - Window 0 (logs): Live gateway log tail"
echo "   - Window 1 (cli):  Interactive shell for clawdbot commands"
echo ""
echo "Attach with: tmux attach -t $SESSION_NAME"

if [[ "$1" == "--attach" ]]; then
    tmux attach -t "$SESSION_NAME"
fi
