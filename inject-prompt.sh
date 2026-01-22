#!/bin/bash
# inject-prompt.sh - Reliably inject a prompt to a Claude session
# Usage: inject-prompt.sh <session> "prompt text"
#
# Features:
# - Clears existing input
# - Injects via tmux buffer (handles multiline)
# - Verifies injection and retries Enter if needed
# - Configurable timeouts via environment variables
#
# Environment variables (all in seconds):
#   INJECT_CLEAR_DELAY=0.5     - Delay after clearing input
#   INJECT_PASTE_DELAY=2.0     - Delay after pasting (scales with length)
#   INJECT_ENTER_DELAY=2.5     - Delay after sending Enter
#   INJECT_RETRY_DELAY=1.0     - Delay between retry attempts
#   INJECT_MAX_RETRIES=5       - Maximum Enter retry attempts
#   INJECT_BUFFER_DELAY=0.3    - Delay after loading tmux buffer

SESSION="$1"
PROMPT="$2"

# Configurable timing (can be overridden via environment)
# Increased defaults for more reliable delivery
CLEAR_DELAY="${INJECT_CLEAR_DELAY:-0.5}"
BASE_PASTE_DELAY="${INJECT_PASTE_DELAY:-2.0}"
ENTER_DELAY="${INJECT_ENTER_DELAY:-2.5}"
RETRY_DELAY="${INJECT_RETRY_DELAY:-1.0}"
MAX_RETRIES="${INJECT_MAX_RETRIES:-5}"
BUFFER_LOAD_DELAY="${INJECT_BUFFER_DELAY:-0.3}"

if [[ -z "$SESSION" || -z "$PROMPT" ]]; then
    echo "Usage: inject-prompt.sh <session> \"prompt text\""
    echo ""
    echo "Environment variables for timing (in seconds):"
    echo "  INJECT_CLEAR_DELAY=0.5   - Delay after clearing input"
    echo "  INJECT_PASTE_DELAY=2.0   - Base delay after pasting"
    echo "  INJECT_ENTER_DELAY=2.5   - Delay after sending Enter"
    echo "  INJECT_RETRY_DELAY=1.0   - Delay between retries"
    echo "  INJECT_MAX_RETRIES=5     - Max retry attempts"
    echo "  INJECT_BUFFER_DELAY=0.3  - Delay after loading buffer"
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

# Calculate paste delay based on prompt length
# Longer prompts need more time to paste
prompt_len=${#PROMPT}
if [[ $prompt_len -gt 5000 ]]; then
    PASTE_DELAY=$(echo "$BASE_PASTE_DELAY + 2.0" | bc 2>/dev/null || echo "3.5")
elif [[ $prompt_len -gt 2000 ]]; then
    PASTE_DELAY=$(echo "$BASE_PASTE_DELAY + 1.0" | bc 2>/dev/null || echo "2.5")
elif [[ $prompt_len -gt 500 ]]; then
    PASTE_DELAY=$(echo "$BASE_PASTE_DELAY + 0.5" | bc 2>/dev/null || echo "2.0")
else
    PASTE_DELAY="$BASE_PASTE_DELAY"
fi

# Clear any leftover input first
tmux send-keys -t "$SESSION" C-u
sleep "$CLEAR_DELAY"

# Inject via buffer (handles multiline properly)
tmpfile=$(mktemp)
printf '%s' "$PROMPT" > "$tmpfile"
tmux load-buffer -b inject_buf "$tmpfile"

# Small delay after loading buffer to ensure tmux is ready
sleep "$BUFFER_LOAD_DELAY"

tmux paste-buffer -b inject_buf -t "$SESSION"
tmux delete-buffer -b inject_buf 2>/dev/null
rm -f "$tmpfile"

# Wait for paste to fully complete
sleep "$PASTE_DELAY"

# Additional sync - ensure tmux has processed the paste
tmux wait-for -S "inject_sync_$$" 2>/dev/null &
sleep 0.2
tmux wait-for -U "inject_sync_$$" 2>/dev/null || true

# Send Enter
tmux send-keys -t "$SESSION" Enter

# Wait and verify
sleep "$ENTER_DELAY"

# Retry function
retry_enter() {
    local attempt=$1
    echo "Enter attempt $attempt..."
    sleep "$RETRY_DELAY"
    tmux send-keys -t "$SESSION" Enter
    sleep "$ENTER_DELAY"
}

# Check if still shows input prompt (Enter didn't register)
# Multiple patterns indicate the prompt is waiting for Enter
check_needs_enter() {
    local verify=$(tmux capture-pane -t "$SESSION" -p | tail -8)
    # Patterns indicating Enter is needed:
    # - "↵ send" = input prompt ready to send
    # - "queued messages" = messages waiting
    # - Input line ends with our prompt text (not yet submitted)
    # - "Press up to edit" = at input prompt
    if echo "$verify" | grep -qE "(↵ send|queued messages|Press up to edit)"; then
        return 0  # needs Enter
    fi
    # If Claude is thinking/working, Enter was registered
    if echo "$verify" | grep -qE "(esc to interrupt|thinking|Percolating|Reasoning|Reading|Writing)"; then
        return 1  # Enter was received
    fi
    # Check if the last lines contain visible prompt text (not submitted)
    # This catches cases where the UI shows the input but hasn't processed Enter
    if echo "$verify" | grep -qE "^>.*[a-zA-Z]" && ! echo "$verify" | grep -qE "^⏺"; then
        return 0  # might need Enter
    fi
    return 1  # assume OK
}

# Retry loop with configurable max attempts
attempt=1
while check_needs_enter && [[ $attempt -lt $MAX_RETRIES ]]; do
    attempt=$((attempt + 1))
    retry_enter $attempt
done

# Final check
if check_needs_enter; then
    echo "Warning: Enter still not registered after $MAX_RETRIES attempts. Manual intervention needed."
    exit 2
fi

echo "Prompt injected to $SESSION (${prompt_len} chars, paste delay: ${PASTE_DELAY}s)"
exit 0
