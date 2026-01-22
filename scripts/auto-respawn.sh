#!/bin/bash
# Auto-Respawn Script for Claude Instances
# Handles full lifecycle: handoff → kill → respawn → inject continuation

SESSION="$1"
PERCENT="$2"
WORKING_DIR="$3"

CONFIG_FILE="$HOME/.claude/handoff-config.json"
HANDOFF_DIR="$HOME/.claude/handoffs"
INJECT_SCRIPT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"
LOG_FILE="$HANDOFF_DIR/auto-respawn.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Load config
if [ -f "$CONFIG_FILE" ]; then
    AUTO_RESPAWN=$(jq -r '.auto_respawn // false' "$CONFIG_FILE")
    WAIT_SECONDS=$(jq -r '.handoff_wait_seconds // 120' "$CONFIG_FILE")
    NOTIFY_ORCH=$(jq -r '.notify_orchestrator // true' "$CONFIG_FILE")
    EXCLUDED=$(jq -r '.excluded_sessions // [] | .[]' "$CONFIG_FILE")
else
    AUTO_RESPAWN="false"
    WAIT_SECONDS=120
    NOTIFY_ORCH="true"
    EXCLUDED=""
fi

# Check if session is excluded
for excl in $EXCLUDED; do
    if [ "$SESSION" = "$excl" ]; then
        log "Session $SESSION is excluded from auto-respawn"
        exit 0
    fi
done

# Check if auto-respawn is enabled
if [ "$AUTO_RESPAWN" != "true" ]; then
    log "Auto-respawn is disabled. Manual intervention needed for $SESSION"
    exit 0
fi

log "=== AUTO-RESPAWN TRIGGERED for $SESSION at ${PERCENT}% ==="

# Step 1: Inject handoff prompt and wait for completion
log "Step 1: Injecting handoff prompt to $SESSION"
HANDOFF_PROMPT=$(cat "$HOME/.claude/handoff-prompt.md")
"$INJECT_SCRIPT" "$SESSION" "🚨 **AUTO-RESPAWN TRIGGERED at ${PERCENT}%**

$HANDOFF_PROMPT

⚠️ **IMPORTANT:** Auto-respawn is ENABLED. After you save the handoff file, this session will be automatically killed and a fresh instance will continue your work.

You have ${WAIT_SECONDS} seconds to complete the handoff summary." 2>/dev/null

# Step 2: Wait for handoff file to appear
log "Step 2: Waiting up to ${WAIT_SECONDS}s for handoff file..."
TIMESTAMP_START=$(date '+%Y-%m-%d-%H%M')
HANDOFF_FILE=""
WAITED=0

while [ $WAITED -lt $WAIT_SECONDS ]; do
    # Look for handoff file created after we started
    LATEST=$(ls -t "$HANDOFF_DIR"/${SESSION}-*.md 2>/dev/null | head -1)
    if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
        # Check if file was created recently (within last 3 minutes)
        FILE_AGE=$(( $(date +%s) - $(stat -f %m "$LATEST") ))
        if [ $FILE_AGE -lt 180 ]; then
            HANDOFF_FILE="$LATEST"
            log "Handoff file found: $HANDOFF_FILE"
            break
        fi
    fi
    sleep 10
    WAITED=$((WAITED + 10))
    log "  Waiting... ${WAITED}s / ${WAIT_SECONDS}s"
done

if [ -z "$HANDOFF_FILE" ]; then
    log "ERROR: No handoff file created within timeout. Aborting auto-respawn."
    "$INJECT_SCRIPT" claude-0 "⚠️ AUTO-RESPAWN FAILED for $SESSION

No handoff file created within ${WAIT_SECONDS}s.
Manual intervention needed." 2>/dev/null
    exit 1
fi

# Step 3: Extract continuation prompt from handoff
log "Step 3: Extracting continuation info from handoff"
CONTINUATION=$(grep -A 100 "## Continuation Prompt" "$HANDOFF_FILE" | grep -A 100 '```' | head -50 | tail -n +2 | grep -B 100 '```' | head -n -1)

if [ -z "$CONTINUATION" ]; then
    # Fallback continuation
    CONTINUATION="Continue from where previous session left off. Read handoff: cat $HANDOFF_FILE"
fi

# Step 4: Kill old session
log "Step 4: Killing old session $SESSION"
tmux kill-session -t "$SESSION" 2>/dev/null
sleep 2

# Step 5: Determine working directory
if [ -z "$WORKING_DIR" ]; then
    # Try to extract from handoff
    WORKING_DIR=$(grep "Working Directory:" "$HANDOFF_FILE" | head -1 | sed 's/.*: //' | tr -d '`')
fi
[ -z "$WORKING_DIR" ] && WORKING_DIR="$HOME"

# Step 6: Start fresh session
log "Step 5: Starting fresh $SESSION in $WORKING_DIR"
cd "$WORKING_DIR"
tmux new-session -d -s "$SESSION" "claude --dangerously-skip-permissions"
sleep 4

# Step 7: Inject continuation prompt
log "Step 6: Injecting continuation prompt"
"$INJECT_SCRIPT" "$SESSION" "🚀 **AUTO-RESPAWN COMPLETE - Fresh Instance**

Previous session hit context threshold (${PERCENT}%).
Handoff file: $HANDOFF_FILE

## Read Your Handoff First
\`\`\`bash
cat $HANDOFF_FILE
\`\`\`

## Your Continuation
$CONTINUATION

## Context Awareness (CRITICAL)
**Threshold is 50%.** Check context BEFORE starting each new task:
\`\`\`bash
~/.claude/scripts/check-context.sh
\`\`\`

**Rules:**
- **<40%:** OK to start new tasks
- **40-49%:** Only start small tasks, consider if next task fits
- **>=50%:** Do NOT start new tasks - complete current work and hand off

Before each TODO item, run the check. If at/near threshold:
1. Mark remaining TODOs as \"not started\" in your summary
2. Write handoff immediately (don't wait for auto-trigger)
3. Save to: \`~/.claude/handoffs/\$(tmux display-message -p '#S')-\$(date '+%Y-%m-%d-%H%M').md\`

## Reporting
- Telegram: \`~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') \"msg\"\`
- TTS: \`~/.claude/scripts/tts-write.sh \"msg\"\`
- System time: \`date '+%Y-%m-%d %H:%M:%S'\`

**Start by reading the handoff, then continue your work.**" 2>/dev/null

# Step 8: Notify orchestrator
if [ "$NOTIFY_ORCH" = "true" ] && [ "$SESSION" != "claude-0" ]; then
    log "Step 7: Notifying orchestrator"
    "$INJECT_SCRIPT" claude-0 "✅ AUTO-RESPAWN COMPLETE: $SESSION

Old session killed at ${PERCENT}% context.
Fresh instance started with continuation from:
$HANDOFF_FILE

No action needed - agent is continuing autonomously." 2>/dev/null
fi

# Step 9: Telegram notification
~/.claude/telegram-orchestrator/send-summary.sh --session auto-respawn "🔄 <b>Auto-Respawn Complete</b>

📋 <b>Session:</b> $SESSION
📊 <b>Trigger:</b> ${PERCENT}% context
✅ <b>Status:</b> Fresh instance running

📁 <b>Handoff:</b> $(basename $HANDOFF_FILE)
💡 <i>Continuing autonomously</i>" 2>/dev/null

# Clear the trigger flag for the new session
rm -f "$HANDOFF_DIR/.triggered-$SESSION"

log "=== AUTO-RESPAWN COMPLETE for $SESSION ==="
