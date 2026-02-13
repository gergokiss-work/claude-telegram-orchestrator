#!/bin/bash
# recover-session.sh - Recover a dead/crashed Claude session with full context
# Usage: recover-session.sh <session-name>
#
# Checks ALL sources in priority order:
#   1. Handoff files (most recent, validated as filled-in)
#   2. Session state files (orchestrator/sessions/)
#   3. Tmux logs (largest file for this session)
#   4. Git/PR state in the session's working directory
#
# Outputs a ready-to-inject continuation prompt to stdout.
# Can also directly start and inject if --start flag is used.

set +e  # Don't exit on errors - we handle failures gracefully

SESSION="$1"
ACTION="${2:---dry-run}"  # --dry-run (default) or --start

if [[ -z "$SESSION" ]]; then
    echo "Usage: recover-session.sh <session-name> [--start|--dry-run]"
    echo ""
    echo "  --dry-run   Show what would be injected (default)"
    echo "  --start     Kill old session, start fresh, inject continuation"
    exit 1
fi

HANDOFF_DIR="$HOME/.claude/handoffs"
SESSION_DIR="$HOME/.claude/telegram-orchestrator/sessions"
LOG_DIR="$HOME/.claude/logs/tmux"
INJECT_SCRIPT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"
WORKER_MD="$HOME/.claude/telegram-orchestrator/worker-claude.md"

log() { echo "[recover] $1" >&2; }

# ============================================================
# Source 1: Handoff files (most recent, must be filled in)
# ============================================================
HANDOFF_FILE=""
HANDOFF_MISSION=""
HANDOFF_DIR_PATH=""
HANDOFF_BRANCH=""
HANDOFF_CONTINUATION=""

# Find most recent handoff for this session (exact match, not prefix)
LATEST_HANDOFF=$(ls -t "$HANDOFF_DIR/${SESSION}-"*.md 2>/dev/null | head -1)

if [[ -n "$LATEST_HANDOFF" ]] && [[ -f "$LATEST_HANDOFF" ]]; then
    # Check if it's filled in (not just template placeholders)
    if grep -q '{SESSION_NAME}\|{CLEAR_GOAL_STATEMENT}\|{TIMESTAMP}' "$LATEST_HANDOFF"; then
        log "Handoff $LATEST_HANDOFF is unfilled template, skipping"
    else
        HANDOFF_FILE="$LATEST_HANDOFF"
        HANDOFF_MISSION=$(grep -A2 "^## 🎯 Mission" "$HANDOFF_FILE" | grep "^>" | sed 's/^> //')
        HANDOFF_DIR_PATH=$(grep "^\*\*Directory:\*\*" "$HANDOFF_FILE" | sed 's/\*\*Directory:\*\* //' | tr -d '`')
        HANDOFF_BRANCH=$(grep "^\*\*Branch:\*\*" "$HANDOFF_FILE" | sed 's/\*\*Branch:\*\* //' | tr -d '`')
        HANDOFF_CONTINUATION=$(sed -n '/^## ⏭️ Continuation Prompt/,/^## /p' "$HANDOFF_FILE" | sed -n '/^```$/,/^```$/p' | sed '1d;$d')
        log "Found valid handoff: $HANDOFF_FILE"
        log "  Mission: $HANDOFF_MISSION"
        log "  Dir: $HANDOFF_DIR_PATH"
        log "  Branch: $HANDOFF_BRANCH"
    fi
else
    log "No handoff files found for $SESSION"
fi

# ============================================================
# Source 2: Session state file
# ============================================================
SESSION_CWD=""
SESSION_TASK=""
SESSION_STARTED=""

SESSION_FILE="$SESSION_DIR/$SESSION"
if [[ -f "$SESSION_FILE" ]]; then
    SESSION_CWD=$(jq -r '.cwd // ""' "$SESSION_FILE" 2>/dev/null)
    SESSION_TASK=$(jq -r '.task // ""' "$SESSION_FILE" 2>/dev/null)
    SESSION_STARTED=$(jq -r '.started // ""' "$SESSION_FILE" 2>/dev/null)
    SESSION_RESUME=$(jq -r '.resumed_from // ""' "$SESSION_FILE" 2>/dev/null)
    SESSION_QUERY=$(jq -r '.resume_query // ""' "$SESSION_FILE" 2>/dev/null)
    log "Session file: cwd=$SESSION_CWD, task=${SESSION_TASK:0:50}, started=$SESSION_STARTED"
fi

# ============================================================
# Source 3: Tmux logs (largest = most work)
# ============================================================
LOG_TASK=""
LOG_ACTIONS=""
LOG_WORKDIR=""

LARGEST_LOG=$(ls -S "$LOG_DIR/${SESSION}_"*.log 2>/dev/null | head -1)
if [[ -n "$LARGEST_LOG" ]] && [[ -f "$LARGEST_LOG" ]]; then
    LOG_SIZE=$(wc -c < "$LARGEST_LOG")
    log "Largest log: $LARGEST_LOG ($LOG_SIZE bytes)"

    # Extract real user prompts (not startup hints)
    LOG_TASK=$(grep -E "❯ " "$LARGEST_LOG" 2>/dev/null \
        | grep -vE 'Try "|refactor <|how do I |how does |bypass permissions|shift.*tab' \
        | awk 'length > 20' \
        | head -1 \
        | sed 's/.*❯ //')

    # Extract recent actions
    LOG_ACTIONS=$(grep -E "^⏺|Bash\(|Read |Edit |Task\(" "$LARGEST_LOG" 2>/dev/null | tail -10 | sed 's/^/  /')

    # Extract working directory from shell prompts
    # Filter to actual directories (not files), exclude internal paths
    LOG_WORKDIR=$(grep -oE '/Users/gergokiss/[a-zA-Z0-9/_-]+' "$LARGEST_LOG" 2>/dev/null \
        | grep -vE '\.claude/|\.log|/tmp/|\.env|\.md|\.ts|\.js|\.json|\.sh|\.py' \
        | grep -E '(work|git|Sites|Documents)/' \
        | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    # Ensure it's actually a directory
    if [[ -n "$LOG_WORKDIR" ]] && [[ ! -d "$LOG_WORKDIR" ]]; then
        # Try parent directory
        LOG_WORKDIR=$(dirname "$LOG_WORKDIR")
        [[ ! -d "$LOG_WORKDIR" ]] && LOG_WORKDIR=""
    fi

    # Extract last Telegram summary content
    LOG_SUMMARY=$(grep -oE 'send-summary.sh[^"]*"[^"]*"' "$LARGEST_LOG" 2>/dev/null | tail -1 | sed 's/send-summary.sh[^"]*"//' | sed 's/"$//')

    log "  Task: ${LOG_TASK:0:80}"
    log "  WorkDir: $LOG_WORKDIR"
fi

# ============================================================
# Determine best working directory
# ============================================================
WORK_DIR=""
# Priority: handoff > log (most frequent path) > session file > home
if [[ -n "$HANDOFF_DIR_PATH" ]] && [[ -d "$HANDOFF_DIR_PATH" ]]; then
    WORK_DIR="$HANDOFF_DIR_PATH"
elif [[ -n "$LOG_WORKDIR" ]] && [[ -d "$LOG_WORKDIR" ]]; then
    WORK_DIR="$LOG_WORKDIR"
elif [[ -n "$SESSION_CWD" ]] && [[ -d "$SESSION_CWD" ]] && [[ "$SESSION_CWD" != "$HOME" ]]; then
    WORK_DIR="$SESSION_CWD"
else
    WORK_DIR="$HOME"
fi
log "Working directory: $WORK_DIR"

# ============================================================
# Source 4: Git/PR state in working directory
# ============================================================
GIT_BRANCH=""
GIT_STATUS=""
GIT_PR=""

if [[ -d "$WORK_DIR/.git" ]] || (cd "$WORK_DIR" && git rev-parse --git-dir &>/dev/null 2>&1); then
    GIT_BRANCH=$(cd "$WORK_DIR" && git branch --show-current 2>/dev/null)
    GIT_STATUS=$(cd "$WORK_DIR" && git status --short 2>/dev/null | head -10)
    # Check for open PRs on this branch
    GIT_PR=$(cd "$WORK_DIR" && gh pr list --head "$GIT_BRANCH" --state open --json number,title --jq '.[0] | "#\(.number): \(.title)"' 2>/dev/null)
    log "Git: branch=$GIT_BRANCH, pr=$GIT_PR"
fi

# ============================================================
# Build continuation prompt
# ============================================================
PROMPT=""

# Use handoff continuation if available
if [[ -n "$HANDOFF_CONTINUATION" ]]; then
    PROMPT="$HANDOFF_CONTINUATION"
    log "Using handoff continuation prompt"
else
    # Build from all available sources
    PROMPT="You are $SESSION recovering from a crashed/dead session."
    PROMPT="$PROMPT
Working directory: $WORK_DIR"

    [[ -n "$GIT_BRANCH" ]] && PROMPT="$PROMPT
Git branch: $GIT_BRANCH"

    [[ -n "$GIT_PR" ]] && PROMPT="$PROMPT
Open PR: $GIT_PR"

    if [[ -n "$HANDOFF_MISSION" ]]; then
        PROMPT="$PROMPT

MISSION (from handoff): $HANDOFF_MISSION"
    fi

    if [[ -n "$LOG_TASK" ]]; then
        PROMPT="$PROMPT

ORIGINAL TASK (from logs): $LOG_TASK"
    fi

    if [[ -n "$SESSION_TASK" ]] && [[ "$SESSION_TASK" != "null" ]] && [[ ${#SESSION_TASK} -gt 5 ]]; then
        PROMPT="$PROMPT

INITIAL TASK (from session file): $SESSION_TASK"
    fi

    if [[ -n "$GIT_STATUS" ]]; then
        PROMPT="$PROMPT

UNCOMMITTED CHANGES:
$GIT_STATUS"
    fi

    if [[ -n "$LOG_ACTIONS" ]]; then
        PROMPT="$PROMPT

RECENT ACTIONS (from tmux logs):
$LOG_ACTIONS"
    fi

    if [[ -n "$HANDOFF_FILE" ]]; then
        PROMPT="$PROMPT

Read your full handoff for more context: cat $HANDOFF_FILE"
    fi

    PROMPT="$PROMPT

Check git status and any open PRs. Continue the work. Send a Telegram summary of your status.
<tg>send-summary.sh</tg>"

    log "Built prompt from multiple sources"
fi

# ============================================================
# Output or execute
# ============================================================
if [[ "$ACTION" == "--start" ]]; then
    log "Starting fresh session..."

    # Kill existing
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    sleep 1

    # Start new session in the right directory
    tmux new-session -d -s "$SESSION" -c "$WORK_DIR"
    tmux pipe-pane -t "$SESSION" "exec $HOME/.claude/scripts/tmux-log-pipe.sh '$SESSION'" 2>/dev/null || true

    # Build session-specific prompt with identity baked in
    SESSION_PROMPT="/tmp/claude-prompt-${SESSION}.md"
    if [[ "$SESSION" == "claude-0" ]] || [[ "$SESSION" == "claude-0-acc2" ]]; then
        COORD_MD="$HOME/.claude/telegram-orchestrator/coordinator-claude.md"
        [ -f "$COORD_MD" ] && sed "s/{SESSION_IDENTITY}/$SESSION/g" "$COORD_MD" > "$SESSION_PROMPT"
    else
        [ -f "$WORKER_MD" ] && sed "s/{SESSION_IDENTITY}/$SESSION/g" "$WORKER_MD" > "$SESSION_PROMPT"
    fi

    # Detect account and start
    if [[ "$SESSION" == *-acc2 ]]; then
        tmux send-keys -t "$SESSION" "CLAUDE_CONFIG_DIR=$HOME/.claude-account2 claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $SESSION_PROMPT)\"" Enter
    else
        tmux send-keys -t "$SESSION" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $SESSION_PROMPT)\"" Enter
    fi

    # Wait for boot
    BOOT_WAITED=0
    while [[ $BOOT_WAITED -lt 45 ]]; do
        sleep 3
        BOOT_WAITED=$((BOOT_WAITED + 3))
        if tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -qiE "bypass permissions|% left|Try \""; then
            log "Claude booted after ${BOOT_WAITED}s"
            break
        fi
    done
    sleep 2

    # Inject
    "$INJECT_SCRIPT" "$SESSION" "$PROMPT" 2>/dev/null
    log "Continuation prompt injected"
    echo "Session $SESSION recovered and running in $WORK_DIR"
else
    # Dry run - just output the prompt
    echo "=== RECOVERY SUMMARY ==="
    echo "Session:    $SESSION"
    echo "WorkDir:    $WORK_DIR"
    echo "Git Branch: ${GIT_BRANCH:-unknown}"
    echo "Open PR:    ${GIT_PR:-none}"
    echo "Handoff:    ${HANDOFF_FILE:-none}"
    echo "Log File:   ${LARGEST_LOG:-none}"
    echo ""
    echo "=== CONTINUATION PROMPT ==="
    echo "$PROMPT"
fi
