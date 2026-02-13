#!/bin/bash
# create-handoff.sh - Create a pre-filled handoff file for the current session
# Usage: create-handoff.sh [mission]
#   mission: Optional one-liner describing what you're working on (default: "Awaiting task")
#
# Auto-detects: session name, timestamp, working dir, git branch, context %
# Outputs the handoff file path to stdout

SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "unknown")
TIMESTAMP=$(date '+%Y-%m-%d-%H%M')
WORKING_DIR=$(pwd)
GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "N/A")
MISSION="${1:-Awaiting task assignment}"

# Context percentage (best effort)
CONTEXT_PCT="0"
CHECK_SCRIPT="$HOME/.claude/scripts/check-context.sh"
if [[ -x "$CHECK_SCRIPT" ]]; then
    CONTEXT_PCT=$("$CHECK_SCRIPT" --percent 2>/dev/null || echo "0")
fi

# Previous handoff (most recent for this session)
PREV_HANDOFF=$(ls -t "$HOME/.claude/handoffs/${SESSION}-"*.md 2>/dev/null | head -1)
if [[ -n "$PREV_HANDOFF" ]]; then
    PREV_HANDOFF_NAME=$(basename "$PREV_HANDOFF")
else
    PREV_HANDOFF_NAME="None"
fi

HANDOFF_FILE="$HOME/.claude/handoffs/${SESSION}-${TIMESTAMP}.md"

cat > "$HANDOFF_FILE" << HANDOFF_EOF
# Handoff: ${SESSION}

**Created:** ${TIMESTAMP}
**Directory:** \`${WORKING_DIR}\`
**Branch:** \`${GIT_BRANCH}\`
**Previous Handoff:** ${PREV_HANDOFF_NAME}

---

## 🎯 Mission
> ${MISSION}

---

## 📍 Current State
**Status:** IN_PROGRESS
**Context Used:** ${CONTEXT_PCT}%
**Last Action:** Session started

---

## 📜 Action Log

| Time | Action | Result |
|------|--------|--------|

---

## 📁 Files Touched

### Read (for context)

### Modified

### Created

---

## 💡 Key Discoveries

---

## 🚧 Blockers / Open Questions

---

## ⏭️ Continuation Prompt

**Copy-paste this to continue the work:**

\`\`\`
You are ${SESSION} continuing from handoff ${SESSION}-${TIMESTAMP}.md.

MISSION: ${MISSION}

CURRENT STATE: Just started

IMMEDIATE NEXT STEPS:
1. Check git status
2. Continue work

START BY: Read the handoff for context
\`\`\`

---

## 🔗 Related Resources

- Previous handoff: \`${PREV_HANDOFF_NAME}\`
HANDOFF_EOF

echo "$HANDOFF_FILE"
