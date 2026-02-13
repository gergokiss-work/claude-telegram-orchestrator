#!/bin/bash
# Trigger handoff protocol when context threshold reached
# Now supports auto-respawn mode

SESSION="$1"
PERCENT="$2"
CONFIG_FILE="$HOME/.claude/handoff-config.json"
HANDOFF_PROMPT="$HOME/.claude/handoff-prompt.md"
INJECT_SCRIPT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"
AUTO_RESPAWN_SCRIPT="$HOME/.claude/scripts/auto-respawn.sh"

# Safety check
if [ -z "$SESSION" ] || [ "$SESSION" = "unknown" ]; then
    exit 0
fi

# Check if session is excluded
if [ -f "$CONFIG_FILE" ]; then
    EXCLUDED=$(jq -r --arg s "$SESSION" '.excluded_sessions // [] | index($s)' "$CONFIG_FILE")
    if [ "$EXCLUDED" != "null" ]; then
        exit 0
    fi
fi

# Get working directory from tmux
WORKING_DIR=$(tmux display-message -t "$SESSION" -p '#{pane_current_path}' 2>/dev/null)

# Check if auto-respawn is enabled
AUTO_RESPAWN="false"
if [ -f "$CONFIG_FILE" ]; then
    AUTO_RESPAWN=$(jq -r '.auto_respawn // false' "$CONFIG_FILE")
fi

# Log
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Handoff triggered for $SESSION at ${PERCENT}% (auto_respawn=$AUTO_RESPAWN)" >> "$HOME/.claude/handoffs/trigger.log"

if [ "$AUTO_RESPAWN" = "true" ]; then
    # Run auto-respawn in background
    nohup "$AUTO_RESPAWN_SCRIPT" "$SESSION" "$PERCENT" "$WORKING_DIR" &>/dev/null &
else
    # Manual mode - just inject prompt and notify
    if [ -f "$HANDOFF_PROMPT" ]; then
        PROMPT=$(cat "$HANDOFF_PROMPT")
    else
        PROMPT="🚨 CONTEXT THRESHOLD (${PERCENT}%) REACHED - Create a detailed handoff summary NOW"
    fi
    
    "$INJECT_SCRIPT" "$SESSION" "🚨 **CONTEXT THRESHOLD REACHED: ${PERCENT}%**

$PROMPT" 2>/dev/null &

    # Notify claude-0
    if [ "$SESSION" != "claude-0" ]; then
        "$INJECT_SCRIPT" claude-0 "⚠️ CONTEXT ALERT: $SESSION reached ${PERCENT}%

Auto-respawn is DISABLED. Manual intervention needed.
Monitor for handoff file in ~/.claude/handoffs/" 2>/dev/null &
    fi
fi
