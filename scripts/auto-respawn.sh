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

# Step 0: Check for active Agent Teams / child processes
# Opus 4.6 Agent Teams spawns teammate subprocesses under the Claude Code process.
# Killing the parent kills ALL teammates, destroying their work.
TEAMMATE_DETECTED=false
TEAM_LOCK_FILE="$HANDOFF_DIR/.team-active-$SESSION"

# Method 1: Check for team lock file (agents write this when spawning teams)
if [ -f "$TEAM_LOCK_FILE" ]; then
    TEAMMATE_DETECTED=true
    log "Team lock file found for $SESSION"
fi

# Method 2: Check child process count of Claude Code process
PANE_PID=$(tmux list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
if [ -n "$PANE_PID" ]; then
    # Get the claude process (child of shell in tmux pane)
    CLAUDE_PID=$(pgrep -P "$PANE_PID" -f "claude" 2>/dev/null | head -1)
    if [ -n "$CLAUDE_PID" ]; then
        CHILD_COUNT=$(pgrep -P "$CLAUDE_PID" 2>/dev/null | wc -l | tr -d ' ')
        # Claude Code normally has 1-2 child processes (node workers).
        # Agent Teams adds more. Threshold of 3+ indicates active teammates.
        if [ "$CHILD_COUNT" -gt 2 ]; then
            TEAMMATE_DETECTED=true
            log "Multiple child processes ($CHILD_COUNT) detected under Claude PID $CLAUDE_PID - likely Agent Teams"
        fi
    fi
fi

# Method 3: Check tmux pane output for teammate indicators
RECENT_OUTPUT=$(tmux capture-pane -t "$SESSION" -p -S -100 2>/dev/null)
if echo "$RECENT_OUTPUT" | grep -qiE "teammate|team.?lead|peer.?message|spawning.*(agent|teammate)|Task tool.*subagent"; then
    TEAMMATE_DETECTED=true
    log "Teammate keywords detected in session output"
fi

if [ "$TEAMMATE_DETECTED" = true ]; then
    log "Agent Teams active in $SESSION - extending timeout and requesting team completion"
    EXTENDED_WAIT=600  # 10 minutes for team work to complete
    WAIT_SECONDS=$EXTENDED_WAIT

    # Inject team-aware handoff request
    "$INJECT_SCRIPT" "$SESSION" "🚨 **AUTO-RESPAWN TRIGGERED at ${PERCENT}%** - Agent Teams detected!

You have active teammates/subagents. Before respawning:
1. Wait for all teammates to complete their work
2. Collect and summarize teammate results
3. Include teammate state in your handoff (what each was doing, their progress)
4. Then create your handoff file

You have ${WAIT_SECONDS} seconds (extended for team work)." 2>/dev/null

    # Wait for team lock to be removed (agent removes it when teams finish)
    TEAM_WAITED=0
    while [ -f "$TEAM_LOCK_FILE" ] && [ $TEAM_WAITED -lt 300 ]; do
        sleep 10
        TEAM_WAITED=$((TEAM_WAITED + 10))
        log "  Waiting for team lock release... ${TEAM_WAITED}s / 300s"
    done
    if [ -f "$TEAM_LOCK_FILE" ]; then
        log "Team lock not released after 300s, proceeding with respawn anyway"
        rm -f "$TEAM_LOCK_FILE"
    fi
else
    # No teammates - proceed with standard handoff injection (Step 1 below)
    true
fi

# Step 1: Inject handoff prompt and wait for completion
# (Skip if already injected team-aware prompt above)
if [ "$TEAMMATE_DETECTED" = false ]; then
    log "Step 1: Injecting handoff prompt to $SESSION"
    "$INJECT_SCRIPT" "$SESSION" "🚨 **AUTO-RESPAWN TRIGGERED at ${PERCENT}%**

Finalize your handoff file NOW:
1. Add final progress entry to your handoff file
2. Fill the 'Continuation Prompt' section
3. File should already exist from session start - just complete it

If no handoff file exists, create one: ~/.claude/handoffs/${SESSION}-\$(date '+%Y-%m-%d-%H%M').md

You have ${WAIT_SECONDS} seconds." 2>/dev/null
fi

# Step 2: Wait for handoff file to appear
log "Step 2: Waiting up to ${WAIT_SECONDS}s for handoff file..."
TRIGGER_TIME=$(date '+%Y-%m-%d-%H%M')
TRIGGER_EPOCH=$(date +%s)
HANDOFF_FILE=""
WAITED=0

while [ $WAITED -lt $WAIT_SECONDS ]; do
    # Look for handoff files - check BOTH filename timestamp AND file modification time
    for FILE in "$HANDOFF_DIR"/${SESSION}-*.md; do
        [ -f "$FILE" ] || continue

        # Method 1: Check filename timestamp
        FNAME=$(basename "$FILE" .md)
        FILE_TS=$(echo "$FNAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$')
        FILENAME_VALID=false
        if [ -n "$FILE_TS" ]; then
            FILE_DATE=$(echo "$FILE_TS" | sed 's/-\([0-9]\{4\}\)$/ \1/' | sed 's/\(..\)$/:\1/')
            FILE_EPOCH=$(date -j -f "%Y-%m-%d %H:%M" "$FILE_DATE" +%s 2>/dev/null || echo "0")
            TIME_DIFF=$((FILE_EPOCH - TRIGGER_EPOCH))
            # Accept if filename timestamp is within 60s before trigger or after
            [ $TIME_DIFF -ge -60 ] && FILENAME_VALID=true
        fi

        # Method 2: Check file modification time (for updated existing handoffs)
        MOD_EPOCH=$(stat -f %m "$FILE" 2>/dev/null || echo "0")
        MOD_AGE=$((TRIGGER_EPOCH - MOD_EPOCH))
        # Accept if file was modified within 5 minutes (300s) of trigger
        MODTIME_VALID=false
        [ $MOD_AGE -le 300 ] && [ $MOD_AGE -ge -60 ] && MODTIME_VALID=true

        # Accept if EITHER condition is met
        if [ "$FILENAME_VALID" = true ] || [ "$MODTIME_VALID" = true ]; then
            HANDOFF_FILE="$FILE"
            log "Handoff file found: $HANDOFF_FILE (filename_ts: $FILE_TS, mod_age: ${MOD_AGE}s)"
            break 2
        fi
    done
    sleep 10
    WAITED=$((WAITED + 10))
    log "  Waiting... ${WAITED}s / ${WAIT_SECONDS}s"
done

# Final scan after timeout — fixes race condition where file appears during last sleep
if [ -z "$HANDOFF_FILE" ]; then
    for FILE in "$HANDOFF_DIR"/${SESSION}-*.md; do
        [ -f "$FILE" ] || continue
        FNAME=$(basename "$FILE" .md)
        FILE_TS=$(echo "$FNAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$')
        FILENAME_VALID=false
        if [ -n "$FILE_TS" ]; then
            FILE_DATE=$(echo "$FILE_TS" | sed 's/-\([0-9]\{4\}\)$/ \1/' | sed 's/\(..\)$/:\1/')
            FILE_EPOCH=$(date -j -f "%Y-%m-%d %H:%M" "$FILE_DATE" +%s 2>/dev/null || echo "0")
            TIME_DIFF=$((FILE_EPOCH - TRIGGER_EPOCH))
            [ $TIME_DIFF -ge -60 ] && FILENAME_VALID=true
        fi
        MOD_EPOCH=$(stat -f %m "$FILE" 2>/dev/null || echo "0")
        MOD_AGE=$((TRIGGER_EPOCH - MOD_EPOCH))
        MODTIME_VALID=false
        [ $MOD_AGE -le 300 ] && [ $MOD_AGE -ge -60 ] && MODTIME_VALID=true
        if [ "$FILENAME_VALID" = true ] || [ "$MODTIME_VALID" = true ]; then
            HANDOFF_FILE="$FILE"
            log "Handoff file found on final scan: $HANDOFF_FILE"
            break
        fi
    done
fi

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
# Detect account suffix and set config dir
if [[ "$SESSION" == *-acc2 ]]; then
    tmux new-session -d -s "$SESSION" -e "CLAUDE_CONFIG_DIR=$HOME/.claude-account2" "claude --dangerously-skip-permissions"
else
    tmux new-session -d -s "$SESSION" "claude --dangerously-skip-permissions"
fi
sleep 4

# Step 6.5: Check for active task file (ralph-task.sh integration)
TASK_FILE="$HANDOFF_DIR/${SESSION}-task.md"
TASK_SECTION=""
if [ -f "$TASK_FILE" ]; then
    TASK_NAME=$(head -1 "$TASK_FILE" | sed 's/^# Task: //')
    TASK_PROGRESS=$(grep -cE "^\s*- \[x\]" "$TASK_FILE" 2>/dev/null || echo "0")
    TASK_TOTAL=$(grep -cE "^\s*- \[[ x]\]" "$TASK_FILE" 2>/dev/null || echo "0")
    log "Active task found: $TASK_NAME ($TASK_PROGRESS/$TASK_TOTAL complete)"
    TASK_SECTION="
## 🎯 ACTIVE TASK (ralph-task.sh)

You have an active task file: \`$TASK_FILE\`
**Task:** $TASK_NAME
**Progress:** $TASK_PROGRESS/$TASK_TOTAL checkboxes complete

Read your task file FIRST:
\`\`\`bash
cat $TASK_FILE
\`\`\`

Continue working on this task. Update checkboxes as you complete them.
When ALL done, set EXIT_SIGNAL: true in the task file.
"
fi

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
$TASK_SECTION
## Context Awareness (CRITICAL)
**Threshold is 50%.** Check context BEFORE starting each new task:
\`\`\`bash
~/.claude/scripts/check-context.sh
\`\`\`

**Rules:**
- **<40%:** OK to start new tasks
- **40-49%:** Only start small tasks, consider if next task fits
- **>=50%:** Do NOT start new tasks - complete current work and hand off

## 📝 HANDOFF PROTOCOL

**FIRST:** Read previous handoff, then create YOUR handoff file immediately:
\`\`\`bash
SESSION=\$(tmux display-message -p '#S')
TIMESTAMP=\$(date '+%Y-%m-%d-%H%M')
# Create: ~/.claude/handoffs/\${SESSION}-\${TIMESTAMP}.md
\`\`\`

**AS YOU WORK:** Add timestamped entries to Progress Log
**AT THRESHOLD:** Fill Continuation Prompt section - file is already complete

## Reporting
- Telegram: \`~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') \"msg\"\`
- TTS: \`~/.claude/scripts/tts-write.sh \"msg\"\`

**Start now: 1) Read handoff, 2) Create your handoff file, 3) Work.**" 2>/dev/null

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

# Step 10: Check if ralph-worker was running and restart it
WORKER_STATE_DIR="$HOME/.claude/telegram-orchestrator/worker-state/$SESSION"
WORKER_STATE_FILE="$WORKER_STATE_DIR/state.json"
if [ -f "$WORKER_STATE_FILE" ]; then
    WORKER_STATUS=$(jq -r '.status // "unknown"' "$WORKER_STATE_FILE" 2>/dev/null)
    if [ "$WORKER_STATUS" = "running" ]; then
        log "Step 10: Restarting ralph-worker"
        WORKER_TASK=$(jq -r '.task_file // ""' "$WORKER_STATE_FILE" 2>/dev/null)
        WORKER_LOOPS=$(jq -r '.loop_count // 0' "$WORKER_STATE_FILE" 2>/dev/null)
        MAX_LOOPS=$((100 - WORKER_LOOPS))  # Resume with remaining loops

        if [ -n "$WORKER_TASK" ] && [ -f "$WORKER_TASK" ] && [ $MAX_LOOPS -gt 0 ]; then
            # Reset worker state for fresh start
            jq '.status = "restarting" | .loop_count = '"$WORKER_LOOPS"'' "$WORKER_STATE_FILE" > "${WORKER_STATE_FILE}.tmp" && mv "${WORKER_STATE_FILE}.tmp" "$WORKER_STATE_FILE"

            # Wait for session to be ready
            sleep 5

            # Restart worker in background
            nohup ~/.claude/telegram-orchestrator/ralph-worker.sh "$SESSION" --task-file "$WORKER_TASK" --max-loops "$MAX_LOOPS" >> "$WORKER_STATE_DIR/worker.log" 2>&1 &
            log "Ralph-worker restarted with $MAX_LOOPS remaining loops"

            ~/.claude/telegram-orchestrator/send-summary.sh --session "$SESSION" "🔄 <b>RALPH Worker Restarted</b>

<b>Session:</b> $SESSION
<b>Previous Loops:</b> $WORKER_LOOPS
<b>Remaining:</b> $MAX_LOOPS
Worker continuing after auto-respawn." 2>/dev/null
        fi
    fi
fi

# Clear the trigger flag for the new session
rm -f "$HANDOFF_DIR/.triggered-$SESSION"

log "=== AUTO-RESPAWN COMPLETE for $SESSION ==="
