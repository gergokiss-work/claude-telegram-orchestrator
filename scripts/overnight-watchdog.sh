#!/bin/bash
# overnight-watchdog.sh — Keep a Claude session alive and working overnight
# Monitors for crashes and idle. Does NOT respawn on context % (auto-compaction handles it).
#
# Usage:
#   overnight-watchdog.sh <session> [--task-file <path>] [--project-dir <path>]
#   overnight-watchdog.sh <session> --stop
#   overnight-watchdog.sh --stop-all
#
# Examples:
#   overnight-watchdog.sh claude-11 --task-file ~/.claude/handoffs/claude-11-overnight-audit-task.md
#   overnight-watchdog.sh claude-12 --project-dir ~/work/gergo/electro-hussars-com
#   overnight-watchdog.sh claude-11 --stop

set -uo pipefail

# --- Parse args ---
SESSION=""
TASK_FILE=""
PROJECT_DIR=""
STOP=false
STOP_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stop)      STOP=true; shift ;;
        --stop-all)  STOP_ALL=true; shift ;;
        --task-file) TASK_FILE="$2"; shift 2 ;;
        --project-dir) PROJECT_DIR="$2"; shift 2 ;;
        -*)          echo "Unknown flag: $1"; exit 1 ;;
        *)           [[ -z "$SESSION" ]] && SESSION="$1" || { echo "Unexpected arg: $1"; exit 1; }; shift ;;
    esac
done

# --- Paths ---
INJECT_SCRIPT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"
SEND_SUMMARY="$HOME/.claude/telegram-orchestrator/send-summary.sh"
WORKER_MD="$HOME/.claude/telegram-orchestrator/worker-claude.md"
HANDOFF_DIR="$HOME/.claude/handoffs"

# --- Stop all ---
if $STOP_ALL; then
    for pidfile in "$HANDOFF_DIR"/.watchdog-*.pid; do
        [[ -f "$pidfile" ]] || continue
        local_session=$(basename "$pidfile" .pid | sed 's/^\.watchdog-//')
        kill "$(cat "$pidfile")" 2>/dev/null && echo "Stopped watchdog for $local_session" || echo "Already stopped: $local_session"
        rm -f "$pidfile"
    done
    exit 0
fi

[[ -z "$SESSION" ]] && { echo "Usage: overnight-watchdog.sh <session> [--task-file <path>] [--project-dir <path>]"; exit 1; }

PID_FILE="$HANDOFF_DIR/.watchdog-${SESSION}.pid"
LOG_FILE="$HANDOFF_DIR/watchdog-${SESSION}.log"

# --- Stop single ---
if $STOP; then
    if [[ -f "$PID_FILE" ]]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null
        rm -f "$PID_FILE"
        echo "Watchdog stopped for $SESSION"
    else
        echo "No watchdog running for $SESSION"
    fi
    exit 0
fi

# --- Prevent duplicate ---
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Watchdog already running for $SESSION (PID $OLD_PID)"
        exit 1
    fi
fi

echo $$ > "$PID_FILE"
trap "rm -f '$PID_FILE'" EXIT

# --- Auto-detect project dir from tmux if not given ---
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR=$(tmux display-message -t "$SESSION" -p '#{pane_current_path}' 2>/dev/null || echo "$HOME")
fi

# --- Auto-detect task file if not given ---
if [[ -z "$TASK_FILE" ]]; then
    TASK_FILE=$(ls -t "$HANDOFF_DIR"/${SESSION}-*task*.md 2>/dev/null | head -1)
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# --- Config ---
CHECK_INTERVAL=120
IDLE_THRESHOLD=300          # 5 min = soft nudge
IDLE_HARD_THRESHOLD=600     # 10 min = hard push
MAX_RESPAWNS=50
RESPAWN_COUNT=0
CONSECUTIVE_IDLE=0
LAST_ACTIVITY_EPOCH=$(date +%s)

log "=== WATCHDOG STARTED: $SESSION ==="
log "Project: $PROJECT_DIR"
log "Task file: ${TASK_FILE:-none}"

# --- Detection ---
is_session_alive() { tmux has-session -t "$SESSION" 2>/dev/null; }

is_at_shell_prompt() {
    local content
    content=$(tmux capture-pane -t "$SESSION" -p -S -3 2>/dev/null)
    echo "$content" | grep -qE '^\$|^%|^bash-|^gergokiss@'
}

is_claude_active() {
    local content
    content=$(tmux capture-pane -t "$SESSION" -p -S -5 2>/dev/null)
    # Match Claude Code spinner words + active indicators
    echo "$content" | grep -qiE "thinking|Running|Reading|Writing|Searching|Editing|esc to interrupt|ctrl\+o|background tasks|local agents|Crafting|Brewing|Cogitating|Precipitating|Percolating|Wrangling|Cerebrating|Leavening|Misting|Proofing|Swirling"
}

get_context_percent() {
    local content
    content=$(tmux capture-pane -t "$SESSION" -p -S -5 2>/dev/null)
    echo "$content" | grep -oE '[0-9]+% \(' | head -1 | grep -oE '^[0-9]+'
}

# --- Restart ---
restart_claude() {
    local reason="$1"
    RESPAWN_COUNT=$((RESPAWN_COUNT + 1))
    log "RESPAWN #$RESPAWN_COUNT: $reason"

    tmux kill-session -t "$SESSION" 2>/dev/null
    sleep 2

    tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR"
    sleep 1

    # Enable logging
    tmux pipe-pane -t "$SESSION" "exec $HOME/.claude/scripts/tmux-log-pipe.sh '$SESSION'" 2>/dev/null || true

    if [[ -f "$WORKER_MD" ]]; then
        tmux send-keys -t "$SESSION" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $WORKER_MD)\"" Enter
    else
        tmux send-keys -t "$SESSION" "claude --dangerously-skip-permissions" Enter
    fi
    sleep 8

    # Find latest handoff
    local handoff
    handoff=$(ls -t "$HANDOFF_DIR"/${SESSION}-*.md 2>/dev/null | grep -v 'task' | head -1)

    local handoff_section=""
    if [[ -n "$handoff" ]]; then
        handoff_section="
Read your previous handoff: \`cat $handoff\`"
    fi

    local task_section=""
    if [[ -n "$TASK_FILE" ]] && [[ -f "$TASK_FILE" ]]; then
        task_section="
Read your task: \`cat $TASK_FILE\`"
    fi

    "$INJECT_SCRIPT" "$SESSION" "🚀 **WATCHDOG RESPAWN** (#$RESPAWN_COUNT)

Reason: $reason
$task_section
$handoff_section

Resume working immediately. Do NOT wait for instructions." 2>/dev/null

    "$SEND_SUMMARY" --session "watchdog" "🔄 <b>Watchdog Respawn</b>

📋 <b>Session:</b> $SESSION (#$RESPAWN_COUNT)
📝 <b>Reason:</b> $reason" 2>/dev/null &

    CONSECUTIVE_IDLE=0
    LAST_ACTIVITY_EPOCH=$(date +%s)
    log "Respawn complete"
}

# --- Nudge ---
nudge() {
    local level="$1"
    local task_hint=""
    [[ -n "$TASK_FILE" ]] && task_hint=" Re-read your task: \`cat $TASK_FILE\`"

    if [[ "$level" == "soft" ]]; then
        "$INJECT_SCRIPT" "$SESSION" "⏰ **Watchdog:** Are you still working? Check what's next and continue.$task_hint Send a Telegram update." 2>/dev/null
    else
        "$INJECT_SCRIPT" "$SESSION" "🚨 **Watchdog:** You've been idle too long. You are an overnight autonomous agent — work continuously.$task_hint Resume NOW." 2>/dev/null
    fi
}

# === MAIN LOOP ===
while true; do
    sleep "$CHECK_INTERVAL"

    if [[ $RESPAWN_COUNT -ge $MAX_RESPAWNS ]]; then
        log "MAX RESPAWNS ($MAX_RESPAWNS) — stopping"
        "$SEND_SUMMARY" --session "watchdog" "⚠️ <b>Watchdog stopped:</b> $SESSION hit $MAX_RESPAWNS respawns" 2>/dev/null &
        break
    fi

    # Crash: session gone
    if ! is_session_alive; then
        log "Session gone — restarting"
        restart_claude "Session crashed or killed"
        continue
    fi

    # Crash: at shell prompt (Claude exited)
    if is_at_shell_prompt; then
        log "At shell prompt — restarting Claude"
        restart_claude "Claude Code not running"
        continue
    fi

    # Context: log only (auto-compaction handles it)
    CTX=$(get_context_percent)
    [[ -n "$CTX" ]] && [[ "$CTX" -ge 70 ]] && log "INFO: Context ${CTX}% — auto-compaction will handle"

    # Activity check
    if is_claude_active; then
        CONSECUTIVE_IDLE=0
        LAST_ACTIVITY_EPOCH=$(date +%s)
    else
        IDLE_TIME=$(( $(date +%s) - LAST_ACTIVITY_EPOCH ))
        CONSECUTIVE_IDLE=$((CONSECUTIVE_IDLE + 1))

        if [[ $IDLE_TIME -ge $IDLE_HARD_THRESHOLD ]]; then
            log "HARD IDLE: ${IDLE_TIME}s (checks: $CONSECUTIVE_IDLE)"
            nudge hard
            # Persistent idle after many checks — force restart
            if [[ $CONSECUTIVE_IDLE -ge 5 ]]; then
                log "Persistent idle — force respawn"
                restart_claude "Persistent idle (${IDLE_TIME}s)"
            fi
        elif [[ $IDLE_TIME -ge $IDLE_THRESHOLD ]]; then
            log "Soft idle: ${IDLE_TIME}s — nudging"
            nudge soft
        fi
    fi

    # Periodic log (~every 20 min)
    [[ $((RANDOM % 10)) -eq 0 ]] && log "Status: ${CTX:-?}% context, respawns=$RESPAWN_COUNT, idle_checks=$CONSECUTIVE_IDLE"
done

log "=== WATCHDOG ENDED ==="
