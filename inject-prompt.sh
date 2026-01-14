#!/bin/bash
# inject-prompt.sh - Reliably inject a prompt to a Claude session
# Usage: inject-prompt.sh <session> "prompt text"
#
# Features:
# - Clears existing input
# - Injects via tmux buffer (handles multiline)
# - Verifies injection and retries Enter if needed
# - Longer timeouts for reliability

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
if echo "$PANE_CONTENT" | grep -qE "(esc to interrupt|thinking|Percolating|Leavening|Misting|Reasoning)"; then
    echo "Warning: $SESSION is currently thinking - injection may queue"
fi

# Clear any leftover input first
tmux send-keys -t "$SESSION" C-u
sleep 0.3

# Inject via buffer (handles multiline properly)
tmpfile=$(mktemp)
printf '%s' "$PROMPT" > "$tmpfile"
tmux load-buffer -b inject_buf "$tmpfile"
tmux paste-buffer -b inject_buf -t "$SESSION"
tmux delete-buffer -b inject_buf 2>/dev/null
rm -f "$tmpfile"

# Wait for paste to fully complete (longer for big prompts)
sleep 1.5

# Send Enter
tmux send-keys -t "$SESSION" Enter

# Wait and verify
sleep 1.5

# Retry function
retry_enter() {
    local attempt=$1
    echo "Enter attempt $attempt..."
    sleep 0.5
    tmux send-keys -t "$SESSION" Enter
    sleep 1.0
}

# Check if still shows input prompt (Enter didn't register)
# Also check for "queued messages" which means Enter is needed
VERIFY=$(tmux capture-pane -t "$SESSION" -p | tail -5)
if echo "$VERIFY" | grep -qE "(↵ send|queued messages)"; then
    retry_enter 2

    VERIFY2=$(tmux capture-pane -t "$SESSION" -p | tail -5)
    if echo "$VERIFY2" | grep -qE "(↵ send|queued messages)"; then
        retry_enter 3

        VERIFY3=$(tmux capture-pane -t "$SESSION" -p | tail -5)
        if echo "$VERIFY3" | grep -qE "(↵ send|queued messages)"; then
            retry_enter 4

            VERIFY4=$(tmux capture-pane -t "$SESSION" -p | tail -5)
            if echo "$VERIFY4" | grep -qE "(↵ send|queued messages)"; then
                echo "Warning: Enter still not registered after 4 attempts. Manual intervention needed."
                exit 2
            fi
        fi
    fi
fi

echo "Prompt injected to $SESSION"
exit 0
