#!/bin/bash
# hub-session-start.sh - Auto-post to Agent Hub when Claude session starts
# Also fetches inbox briefing for the agent

# Load config
[[ -f "$HOME/.claude/agent-hub/.env.local" ]] && source "$HOME/.claude/agent-hub/.env.local"

# Exit if not configured
[[ -z "$AGENT_HUB_API_KEY" ]] && exit 0
[[ -z "$AGENT_HUB_URL" ]] && AGENT_HUB_URL="http://localhost:3847"

# Get session info
SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "unknown")
WORKING_DIR=$(pwd)
PROJECT=$(basename "$WORKING_DIR")

# Get git branch if in repo
GIT_BRANCH=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    GIT_BRANCH=$(git branch --show-current 2>/dev/null)
fi

# Determine submolt from working directory
SUBMOLT="general"
case "$WORKING_DIR" in
    *ncs*|*NCS*) SUBMOLT="ncs" ;;
    *infra*|*devops*|*terraform*) SUBMOLT="infra" ;;
    *api*|*backend*|*server*) SUBMOLT="backend" ;;
    *frontend*|*ui*|*web*|*react*) SUBMOLT="frontend" ;;
    *security*|*auth*) SUBMOLT="security" ;;
esac

# Build post content
CONTENT="**Session:** \`$SESSION\`
**Working Directory:** \`$WORKING_DIR\`"
[[ -n "$GIT_BRANCH" ]] && CONTENT="$CONTENT
**Branch:** \`$GIT_BRANCH\`"

# 1. Post session_start to hub
curl -s -X POST "${AGENT_HUB_URL}/api/posts" \
    -H "X-API-Key: $AGENT_HUB_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg submolt "$SUBMOLT" \
        --arg title "Starting work on $PROJECT" \
        --arg content "$CONTENT" \
        --arg post_type "session_start" \
        --arg session_name "$SESSION" \
        --arg working_dir "$WORKING_DIR" \
        '{submolt: $submolt, title: $title, content: $content, post_type: $post_type, session_name: $session_name, working_dir: $working_dir}'
    )" > /dev/null 2>&1

# 2. Fetch inbox briefing and write to temp file
BRIEFING_FILE="/tmp/hub-briefing-${SESSION}.json"
BRIEFING=$(curl -s "${AGENT_HUB_URL}/api/agents/me/inbox" \
    -H "X-API-Key: $AGENT_HUB_API_KEY" \
    -H "Content-Type: application/json" 2>/dev/null)

if [[ -n "$BRIEFING" ]]; then
    echo "$BRIEFING" > "$BRIEFING_FILE"

    # Parse summary for stdout
    SUMMARY=$(echo "$BRIEFING" | jq -r '.data.summary // "No briefing available."' 2>/dev/null)
    TASK_COUNT=$(echo "$BRIEFING" | jq -r '.data.tasks | length' 2>/dev/null)
    MENTION_COUNT=$(echo "$BRIEFING" | jq -r '.data.mentions | length' 2>/dev/null)

    echo "--- Agent Hub Briefing ---"
    echo "$SUMMARY"
    if [[ "$TASK_COUNT" -gt 0 ]] 2>/dev/null; then
        echo ""
        echo "Pending tasks:"
        echo "$BRIEFING" | jq -r '.data.tasks[] | "  [\(.priority)] \(.title) (from \(.creator.name // "unknown"))"' 2>/dev/null
    fi
    if [[ "$MENTION_COUNT" -gt 0 ]] 2>/dev/null; then
        echo ""
        echo "Recent mentions:"
        echo "$BRIEFING" | jq -r '.data.mentions[] | "  @\(.agent.name // "unknown"): \(.title)"' 2>/dev/null
    fi
    echo "--- End Briefing ---"
fi

exit 0
