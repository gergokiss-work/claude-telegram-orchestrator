#!/bin/bash
# Enhanced handoff-log.sh with significance detection
# Usage: handoff-log.sh "action" "result" [significance]
# Example: handoff-log.sh "Read src/auth.ts" "Found JWT config on line 45"
# Example: handoff-log.sh "Deployed to staging" "Build 1234 live" "critical"
#
# Significance auto-detection:
#   🔴 CRITICAL: edit, modify, delete, create, deploy, push, write, remove, drop
#   🟡 IMPORTANT: test, build, api, install, migrate, run, execute, curl, fetch
#   🟢 ROUTINE: read, check, list, status, search, grep, glob, explore

SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "unknown")
TIME=$(date '+%H:%M')

# Find the most recent handoff file for this session
HANDOFF_DIR="$HOME/.claude/handoffs"
HANDOFF_FILE=$(ls -t "$HANDOFF_DIR"/${SESSION}-*.md 2>/dev/null | head -1)

if [ -z "$HANDOFF_FILE" ]; then
    echo "ERROR: No handoff file found for session $SESSION"
    echo "Create one first: cp ~/.claude/templates/HANDOFF_V3.md ~/.claude/handoffs/${SESSION}-\$(date '+%Y-%m-%d-%H%M').md"
    exit 1
fi

ACTION="$1"
RESULT="$2"
OVERRIDE="$3"

if [ -z "$ACTION" ]; then
    echo "Usage: handoff-log.sh \"action\" \"result\" [critical|important|routine]"
    exit 1
fi

# Determine significance
detect_significance() {
    local action_lower
    action_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    # Check override first
    case "${OVERRIDE}" in
        critical|crit) echo "🔴"; return ;;
        important|imp) echo "🟡"; return ;;
        routine|rout)  echo "🟢"; return ;;
    esac

    # Auto-detect from action text
    if echo "$action_lower" | grep -qiE '\b(edit|modif|delet|creat|deploy|push|writ|wrote|remov|drop|alter|insert|updat|kill|destro|migrat)'; then
        echo "🔴"
    elif echo "$action_lower" | grep -qiE '\b(test|build|api|install|run |execut|curl|fetch|compil|npm|pip|docker|kubectl|git commit)'; then
        echo "🟡"
    else
        echo "🟢"
    fi
}

SIGNIFICANCE=$(detect_significance "$ACTION")

# Append to the Action Log table
echo "| $TIME | $SIGNIFICANCE $ACTION | $RESULT |" >> "$HANDOFF_FILE"
echo "Logged [$SIGNIFICANCE] to $HANDOFF_FILE"
