#!/bin/bash
# inject-prompt.sh - Reliably inject a prompt to a Claude session
# Usage: inject-prompt.sh <session> "prompt text"
#
# Features:
# - Clears existing input
# - Injects via tmux buffer (handles multiline)
# - Verifies injection and retries Enter if needed

SESSION="$1"
PROMPT="$2"

if [[ -z "$SESSION" || -z "$PROMPT" ]]; then
    echo "Usage: inject-prompt.sh <session> \"prompt text\""
    exit 1
fi

# Check session exists
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Error: Session $SESSION does not exist"
    exit 1
fi

# Check if session is thinking (can't inject while thinking)
PANE_CONTENT=$(tmux capture-pane -t "$SESSION" -p | tail -5)
if echo "$PANE_CONTENT" | grep -q "esc to interrupt"; then
    echo "Warning: $SESSION is currently thinking - injection may queue"
fi

# Clear any leftover input
tmux send-keys -t "$SESSION" C-u
sleep 0.2

# Inject via buffer (handles multiline properly)
tmpfile=$(mktemp)
printf '%s' "$PROMPT" > "$tmpfile"
tmux load-buffer -b inject_buf "$tmpfile"
tmux paste-buffer -b inject_buf -t "$SESSION"
tmux delete-buffer -b inject_buf 2>/dev/null
rm -f "$tmpfile"

# Wait for paste to complete
sleep 0.8

# Send Enter
tmux send-keys -t "$SESSION" Enter

# Verify - check if still shows "↵ send" after a moment
sleep 1.0
VERIFY=$(tmux capture-pane -t "$SESSION" -p | tail -3)
if echo "$VERIFY" | grep -q "↵ send"; then
    echo "First Enter didn't take, retrying..."
    sleep 0.5
    tmux send-keys -t "$SESSION" Enter
    sleep 0.5

    # Check again
    VERIFY2=$(tmux capture-pane -t "$SESSION" -p | tail -3)
    if echo "$VERIFY2" | grep -q "↵ send"; then
        echo "Warning: Enter still not registered. May need manual intervention."
        exit 2
    fi
fi

echo "Prompt injected to $SESSION"
exit 0
