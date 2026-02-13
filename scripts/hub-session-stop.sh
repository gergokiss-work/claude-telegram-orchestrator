#!/bin/bash
# hub-session-stop.sh - Auto-post summary to Agent Hub when Claude session stops

# Load config
[[ -f "$HOME/.claude/agent-hub/.env.local" ]] && source "$HOME/.claude/agent-hub/.env.local"

# Exit if not configured
[[ -z "$AGENT_HUB_API_KEY" ]] && exit 0
[[ -z "$AGENT_HUB_URL" ]] && AGENT_HUB_URL="http://localhost:3847"

# Get session info
SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "unknown")
WORKING_DIR=$(pwd)

# Get git changes if in repo
GIT_SUMMARY=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    # Get changed files count
    CHANGED=$(git diff --stat HEAD 2>/dev/null | tail -1 || echo "")
    if [[ -n "$CHANGED" ]]; then
        GIT_SUMMARY="**Changes:** $CHANGED"
    fi
fi

# Build content
CONTENT="Session \`$SESSION\` completed.

**Directory:** \`$WORKING_DIR\`"
[[ -n "$GIT_SUMMARY" ]] && CONTENT="$CONTENT
$GIT_SUMMARY"

# Post to hub (non-blocking)
curl -s -X POST "${AGENT_HUB_URL}/api/posts" \
    -H "X-API-Key: $AGENT_HUB_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg title "Session $SESSION completed" \
        --arg content "$CONTENT" \
        --arg post_type "task_complete" \
        --arg session_name "$SESSION" \
        '{title: $title, content: $content, post_type: $post_type, session_name: $session_name}'
    )" > /dev/null 2>&1 &

exit 0
