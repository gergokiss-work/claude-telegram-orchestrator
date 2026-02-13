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
    log "WARNING: No handoff file created within timeout. Will use tmux log fallback."
    HANDOFF_FILE=""
fi

# Step 3: Validate handoff content and extract continuation
log "Step 3: Validating handoff and extracting continuation info"
HANDOFF_VALID=false
CONTINUATION=""

if [ -n "$HANDOFF_FILE" ] && [ -f "$HANDOFF_FILE" ]; then
    # Check if handoff was actually filled in (not just the empty template)
    # Empty templates contain "{SESSION_NAME}" and "{CLEAR_GOAL_STATEMENT}" placeholders
    if grep -q '{SESSION_NAME}\|{CLEAR_GOAL_STATEMENT}\|{TIMESTAMP}' "$HANDOFF_FILE"; then
        log "WARNING: Handoff file is an unfilled template - using tmux log fallback"
        HANDOFF_VALID=false
    else
        # Check if there's meaningful content (more than just template structure)
        CONTENT_LINES=$(grep -cvE '^\s*$|^#|^-{3,}|^\||^[*-] \[' "$HANDOFF_FILE" 2>/dev/null || echo "0")
        if [ "$CONTENT_LINES" -lt 5 ]; then
            log "WARNING: Handoff file has minimal content ($CONTENT_LINES lines) - using tmux log fallback"
            HANDOFF_VALID=false
        else
            HANDOFF_VALID=true
            CONTINUATION=$(grep -A 100 "## Continuation Prompt" "$HANDOFF_FILE" | grep -A 100 '```' | head -50 | tail -n +2 | grep -B 100 '```' | head -n -1)
        fi
    fi
fi

# Fallback: Extract context from tmux logs if handoff is empty/missing
TMUX_LOG_CONTEXT=""
if [ "$HANDOFF_VALID" = false ]; then
    log "Using tmux log fallback to extract session context"
    # Find the LARGEST log file for this session (most substantial work, not a failed respawn's tiny log)
    LATEST_LOG=$(ls -S "$HOME/.claude/logs/tmux/${SESSION}_"*.log 2>/dev/null | head -1)
    if [ -n "$LATEST_LOG" ] && [ -f "$LATEST_LOG" ]; then
        log "Using log file: $LATEST_LOG ($(wc -c < "$LATEST_LOG") bytes)"

        # Extract real user prompts - filter out:
        #   - Startup hints (Try "...", refactor, how do I)
        #   - Empty prompts
        #   - Very short lines (likely UI artifacts)
        # The ❯ character may have surrounding whitespace/formatting in tmux logs
        INITIAL_TASK=$(grep -E "^❯ " "$LATEST_LOG" 2>/dev/null \
            | grep -vE 'Try "|refactor <|how do I |how does ' \
            | grep -vE '^\s*$|^❯\s*$' \
            | awk 'length > 15' \
            | head -1 \
            | sed 's/^❯ //')

        # If no match with ^❯, try with looser pattern (tmux may strip/add chars)
        if [ -z "$INITIAL_TASK" ]; then
            INITIAL_TASK=$(grep -E "❯ " "$LATEST_LOG" 2>/dev/null \
                | grep -vE 'Try "|refactor <|how do I |how does |bypass permissions|shift\+tab' \
                | grep -vE '^\s*$' \
                | awk 'length > 20' \
                | head -1 \
                | sed 's/.*❯ //')
        fi

        # Extract recent meaningful output (last commands/actions)
        RECENT_ACTIONS=$(grep -E "^⏺|Bash\(|Read |Edit |Task\(" "$LATEST_LOG" 2>/dev/null | tail -10 | head -10 | sed 's/^/  /')

        # Extract working directory from shell prompt patterns
        LOG_WORKDIR=$(grep -oE '/Users/gergokiss/[a-zA-Z0-9/_.-]+' "$LATEST_LOG" 2>/dev/null \
            | grep -vE '\.claude/|\.log|/tmp/' \
            | tail -1)

        # Also check for send-summary content which often describes the task
        LAST_SUMMARY=$(grep -oE 'send-summary.sh[^"]*"[^"]*"' "$LATEST_LOG" 2>/dev/null | tail -1 | sed 's/send-summary.sh[^"]*"//' | sed 's/"$//')

        if [ -n "$INITIAL_TASK" ]; then
            TMUX_LOG_CONTEXT="ORIGINAL TASK: $INITIAL_TASK"
        elif [ -n "$LAST_SUMMARY" ]; then
            TMUX_LOG_CONTEXT="LAST KNOWN WORK (from Telegram summary): $LAST_SUMMARY"
        fi

        if [ -n "$RECENT_ACTIONS" ]; then
            TMUX_LOG_CONTEXT="${TMUX_LOG_CONTEXT}

RECENT ACTIONS (from logs):
$RECENT_ACTIONS"
        fi

        [ -n "$LOG_WORKDIR" ] && WORKING_DIR="$LOG_WORKDIR"
        log "Extracted task: ${INITIAL_TASK:0:100}..."
        [ -n "$LOG_WORKDIR" ] && log "Extracted working dir: $LOG_WORKDIR"
    fi
fi

if [ -z "$CONTINUATION" ] && [ -n "$TMUX_LOG_CONTEXT" ]; then
    CONTINUATION="$TMUX_LOG_CONTEXT"
elif [ -z "$CONTINUATION" ]; then
    CONTINUATION="Continue from where previous session left off."
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

# Step 6: Start fresh session with worker system prompt
log "Step 5: Starting fresh $SESSION in $WORKING_DIR"
WORKER_MD="$HOME/.claude/telegram-orchestrator/worker-claude.md"
COORDINATOR_MD="$HOME/.claude/telegram-orchestrator/coordinator-claude.md"

# Determine which system prompt to use
SYSTEM_PROMPT_FILE=""
if [[ "$SESSION" == "claude-0" ]] || [[ "$SESSION" == "claude-0-acc2" ]]; then
    [ -f "$COORDINATOR_MD" ] && SYSTEM_PROMPT_FILE="$COORDINATOR_MD"
else
    [ -f "$WORKER_MD" ] && SYSTEM_PROMPT_FILE="$WORKER_MD"
fi

# Detect account suffix and set config dir
if [[ "$SESSION" == *-acc2 ]]; then
    tmux new-session -d -s "$SESSION" -c "$WORKING_DIR" -e "CLAUDE_CONFIG_DIR=$HOME/.claude-account2"
else
    tmux new-session -d -s "$SESSION" -c "$WORKING_DIR"
fi

# Enable session logging
tmux pipe-pane -t "$SESSION" "exec $HOME/.claude/scripts/tmux-log-pipe.sh '$SESSION'" 2>/dev/null || true

sleep 1

# Start Claude - use \$(cat file) pattern to avoid shell escaping issues
# The sed/tr approach mangles special characters in the system prompt
if [ -n "$SYSTEM_PROMPT_FILE" ]; then
    tmux send-keys -t "$SESSION" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $SYSTEM_PROMPT_FILE)\"" Enter
else
    tmux send-keys -t "$SESSION" "claude --dangerously-skip-permissions" Enter
fi

# Wait for Claude to fully boot (check for idle prompt)
log "Waiting for Claude to boot..."
BOOT_WAITED=0
BOOT_TIMEOUT=45
while [ $BOOT_WAITED -lt $BOOT_TIMEOUT ]; do
    sleep 3
    BOOT_WAITED=$((BOOT_WAITED + 3))
    BOOT_CHECK=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null)
    # Check multiple patterns - any of these mean Claude is ready
    if echo "$BOOT_CHECK" | grep -qiE "bypass permissions|shift.*tab.*cycle|% left|Try \""; then
        log "Claude booted after ${BOOT_WAITED}s"
        break
    fi
done
if [ $BOOT_WAITED -ge $BOOT_TIMEOUT ]; then
    log "WARNING: Claude boot timeout after ${BOOT_TIMEOUT}s, continuing anyway"
fi
# Extra settle time after boot detection
sleep 2

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
# Write the continuation prompt to a temp file to avoid tmux paste issues
# with large multi-line content containing special characters
log "Step 6: Injecting continuation prompt"
RESPAWN_PROMPT_FILE=$(mktemp /tmp/respawn-prompt-XXXXXX.md)

if [ "$HANDOFF_VALID" = true ]; then
    cat > "$RESPAWN_PROMPT_FILE" << RESPAWN_EOF
You are a respawned session (previous hit ${PERCENT}% context). Read your handoff file first, then continue:

cat $HANDOFF_FILE

$CONTINUATION
$TASK_SECTION
After reading the handoff, continue the work. Send a Telegram summary when you make progress.
RESPAWN_EOF
else
    cat > "$RESPAWN_PROMPT_FILE" << RESPAWN_EOF
You are a respawned session (previous hit ${PERCENT}% context). No valid handoff was saved, but here is what was extracted from the session logs:

$CONTINUATION

Continue this work. Send a Telegram summary when you make progress.
<tg>send-summary.sh</tg>
RESPAWN_EOF
fi

# Inject using the file - inject-prompt.sh handles the tmux buffer/paste
PROMPT_TO_INJECT=$(cat "$RESPAWN_PROMPT_FILE")
"$INJECT_SCRIPT" "$SESSION" "$PROMPT_TO_INJECT" 2>/dev/null
rm -f "$RESPAWN_PROMPT_FILE"

# Step 8: Notify orchestrator
if [ "$NOTIFY_ORCH" = "true" ] && [ "$SESSION" != "claude-0" ]; then
    log "Step 7: Notifying orchestrator"
    if [ "$HANDOFF_VALID" = true ]; then
        RESPAWN_SOURCE="handoff file: $HANDOFF_FILE"
    else
        RESPAWN_SOURCE="tmux log fallback (handoff was empty/missing)"
    fi
    "$INJECT_SCRIPT" claude-0 "✅ AUTO-RESPAWN COMPLETE: $SESSION

Old session killed at ${PERCENT}% context.
Fresh instance started with continuation from: ${RESPAWN_SOURCE}

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
