#!/bin/bash
# Toggle auto-respawn on/off

CONFIG_FILE="$HOME/.claude/handoff-config.json"
ACTION="$1"

case "$ACTION" in
    on|enable)
        jq '.auto_respawn = true' "$CONFIG_FILE" > /tmp/handoff-config.json && mv /tmp/handoff-config.json "$CONFIG_FILE"
        echo "✅ Auto-respawn ENABLED"
        echo "Sessions will automatically respawn at 50% context"
        ;;
    off|disable)
        jq '.auto_respawn = false' "$CONFIG_FILE" > /tmp/handoff-config.json && mv /tmp/handoff-config.json "$CONFIG_FILE"
        echo "⏸️ Auto-respawn DISABLED"
        echo "Manual intervention needed at context threshold"
        ;;
    status)
        STATUS=$(jq -r '.auto_respawn' "$CONFIG_FILE")
        THRESHOLD=$(jq -r '.threshold_percent' "$CONFIG_FILE")
        EXCLUDED=$(jq -r '.excluded_sessions | join(", ")' "$CONFIG_FILE")
        echo "Auto-respawn: $STATUS"
        echo "Threshold: ${THRESHOLD}%"
        echo "Excluded: $EXCLUDED"
        ;;
    exclude)
        SESSION="$2"
        if [ -z "$SESSION" ]; then
            echo "Usage: $0 exclude <session-name>"
            exit 1
        fi
        jq --arg s "$SESSION" '.excluded_sessions += [$s] | .excluded_sessions |= unique' "$CONFIG_FILE" > /tmp/handoff-config.json && mv /tmp/handoff-config.json "$CONFIG_FILE"
        echo "Added $SESSION to exclusion list"
        ;;
    include)
        SESSION="$2"
        if [ -z "$SESSION" ]; then
            echo "Usage: $0 include <session-name>"
            exit 1
        fi
        jq --arg s "$SESSION" '.excluded_sessions -= [$s]' "$CONFIG_FILE" > /tmp/handoff-config.json && mv /tmp/handoff-config.json "$CONFIG_FILE"
        echo "Removed $SESSION from exclusion list"
        ;;
    *)
        echo "Usage: $0 {on|off|status|exclude <session>|include <session>}"
        echo ""
        echo "Commands:"
        echo "  on/enable   - Enable automatic respawn at threshold"
        echo "  off/disable - Disable automatic respawn"
        echo "  status      - Show current configuration"
        echo "  exclude X   - Exclude session X from auto-respawn"
        echo "  include X   - Remove session X from exclusion list"
        exit 1
        ;;
esac
