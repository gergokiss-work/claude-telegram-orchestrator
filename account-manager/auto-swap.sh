#!/bin/bash
# auto-swap.sh - Move Claude sessions from a saturated account to the other one
#
# Flow:
#   1. Check target account is actually usable (not also blocked)
#   2. Find all claude-* sessions on from-account
#   3. Inject handoff requests in parallel
#   4. Wait (up to HANDOFF_TIMEOUT) for handoff files — polling all sessions together
#   5. Kill sessions, restart on to-account, inject continuation
#
# Usage:
#   auto-swap.sh --from-account <1|2> --reason <str>  [--timeout <seconds>] [--dry-run]

AM_DIR="$HOME/.claude/account-manager"
HANDOFF_DIR="$HOME/.claude/handoffs"
SESSIONS_DIR="$HOME/.claude/telegram-orchestrator/sessions"
INJECT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"
TG_SCRIPT="$HOME/.claude/telegram-orchestrator/send-summary.sh"
TTS_SCRIPT="$HOME/.claude/scripts/tts-write.sh"
LOG_PIPE="$HOME/.claude/scripts/tmux-log-pipe.sh"
WORKER_MD="$HOME/.claude/telegram-orchestrator/worker-claude.md"
COORDINATOR_MD="$HOME/.claude/telegram-orchestrator/coordinator-claude.md"
LOG="$AM_DIR/auto-swap.log"
LOCK_DIR="/tmp/claude-auto-swap"

FROM_ACCOUNT=""
REASON="unknown"
HANDOFF_TIMEOUT=300   # 5 min
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-account) FROM_ACCOUNT="$2"; shift 2 ;;
        --reason)       REASON="$2";       shift 2 ;;
        --timeout)      HANDOFF_TIMEOUT="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true;      shift ;;
        *) shift ;;
    esac
done

if [[ -z "$FROM_ACCOUNT" ]]; then
    echo "ERROR: --from-account required" >&2
    exit 1
fi

TO_ACCOUNT="$([[ "$FROM_ACCOUNT" == "1" ]] && echo "2" || echo "1")"
FROM_TAG="$([[ "$FROM_ACCOUNT" == "1" ]] && echo "ns" || echo "nl")"
TO_TAG="$([[ "$TO_ACCOUNT" == "1" ]]   && echo "ns" || echo "nl")"
# ns (account 1): CLAUDE_CONFIG_DIR must be UNSET — credentials live in ~/.claude.json (home level)
# nl (account 2): CLAUDE_CONFIG_DIR=~/.claude-account2
TO_CONFIG="$([[ "$TO_ACCOUNT" == "2" ]] && echo "$HOME/.claude-account2" || echo "UNSET")"

mkdir -p "$LOCK_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ─── Prevent duplicate swap ────────────────────────────────────────────────────
LOCK="$LOCK_DIR/swap-from-${FROM_ACCOUNT}"
if [[ -f "$LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
    if [[ $lock_age -lt 600 ]]; then
        log "Swap from account $FROM_ACCOUNT already in progress (lock age: ${lock_age}s). Skipping."
        exit 0
    fi
    rm -f "$LOCK"
fi
touch "$LOCK"
cleanup() { rm -f "$LOCK"; }
trap cleanup EXIT

# ─── Account detection for a session ──────────────────────────────────────────
get_session_account() {
    local session="$1"

    # 1. File written by claudet on session start (most reliable)
    local file="/tmp/claude-account-${session}"
    if [[ -f "$file" ]]; then
        cat "$file"
        return
    fi

    # 2. Session metadata JSON
    local meta="$SESSIONS_DIR/$session"
    if [[ -f "$meta" ]]; then
        local acc
        acc=$(python3 -c "
import json
try:
    d=json.load(open('$meta'))
    print(int(d.get('account',0) or 0))
except: print(0)
" 2>/dev/null)
        if [[ "$acc" == "1" || "$acc" == "2" ]]; then
            echo "$acc"
            return
        fi
    fi

    # 3. lsof on pane child processes — which settings.json they have open
    local pane_pid
    pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [[ -n "$pane_pid" ]]; then
        local cpid
        while IFS= read -r cpid; do
            if lsof -p "$cpid" 2>/dev/null | grep "settings.json" | grep -q "account2"; then
                echo "2"
                return
            fi
        done < <(pgrep -P "$pane_pid" 2>/dev/null || true)
        echo "1"
        return
    fi

    echo "unknown"
}

# ─── Check target account is usable ───────────────────────────────────────────
check_target_usable() {
    local cache="$AM_DIR/account${TO_ACCOUNT}-usage-cache.json"
    [[ ! -f "$cache" ]] && return 0   # No data = assume usable

    local five_h
    five_h=$(python3 -c "
import json
try:
    d=json.load(open('$cache'))
    print(int(d.get('five_hour',{}).get('utilization',0) or 0))
except: print(0)
" 2>/dev/null || echo "0")

    if [[ "$five_h" -ge 100 ]]; then
        log "WARN: Target account $TO_ACCOUNT ($TO_TAG) also blocked (5h=${five_h}%). Cannot swap."
        "$TTS_SCRIPT" "Both accounts limited. Cannot auto-swap." &>/dev/null &
        "$TG_SCRIPT" --session "auto-swap" "⛔ <b>Auto-Swap Aborted</b>

Both accounts are at their limit.
${FROM_TAG}: triggered swap (${REASON})
${TO_TAG}: also blocked (5h=${five_h}%)

Manual intervention required." &>/dev/null &
        return 1
    fi
    return 0
}

# ─── Find sessions on FROM_ACCOUNT ────────────────────────────────────────────
sessions_to_swap=()
while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    acc=$(get_session_account "$session")
    if [[ "$acc" == "$FROM_ACCOUNT" ]]; then
        sessions_to_swap+=("$session")
        log "Found: $session → account $FROM_ACCOUNT ($FROM_TAG)"
    else
        log "Skip:  $session → account ${acc}"
    fi
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^claude-' || true)

if [[ ${#sessions_to_swap[@]} -eq 0 ]]; then
    log "No sessions on account $FROM_ACCOUNT. Nothing to swap."
    exit 0
fi

log "Initiating swap: $FROM_TAG → $TO_TAG | ${#sessions_to_swap[@]} sessions | reason: $REASON"

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: would swap: ${sessions_to_swap[*]}"
    exit 0
fi

# ─── Pre-flight: target account usable? ───────────────────────────────────────
check_target_usable || exit 1

# ─── Notify user ──────────────────────────────────────────────────────────────
"$TTS_SCRIPT" "Account ${FROM_TAG} at ${REASON}. Auto-swapping ${#sessions_to_swap[@]} sessions to ${TO_TAG}." &>/dev/null &
"$TG_SCRIPT" --session "auto-swap" "🔄 <b>Account Swap Started</b>

⚡ <b>Reason:</b> ${FROM_TAG} hit ${REASON}
📦 <b>Sessions:</b> ${sessions_to_swap[*]}
🎯 <b>Moving to:</b> ${TO_TAG}
⏱ <b>Handoff timeout:</b> ${HANDOFF_TIMEOUT}s" &>/dev/null &

# ─── Phase 1: Inject handoff requests in parallel ─────────────────────────────
TRIGGER_EPOCH=$(date +%s)
SWAP_TIMESTAMP=$(date '+%Y-%m-%d-%H%M')

for session in "${sessions_to_swap[@]}"; do
    rm -f "$LOCK_DIR/handoff-${session}"   # clear stale flags
    handoff_path="$HANDOFF_DIR/${session}-${SWAP_TIMESTAMP}.md"
    msg="🔄 **ACCOUNT SWAP: Create Handoff NOW**

Account **${FROM_TAG}** has reached **${REASON}** usage.
This session is being automatically moved to account **${TO_TAG}**.

Create your handoff file:
\`\`\`bash
cp ~/.claude/templates/HANDOFF_V3.md ${handoff_path}
\`\`\`

Fill in completely:
1. Mission + current state
2. Files modified (paths + what changed)
3. Next steps (specific, actionable)
4. Copy-paste ready Continuation Prompt at the bottom

When done: reply \`HANDOFF_DONE\`
**You have ${HANDOFF_TIMEOUT} seconds.**"

    log "Injecting handoff request → $session"
    "$INJECT" "$session" "$msg" &>/dev/null &
done
wait   # all injections fired

# ─── Phase 2: Wait for handoffs (poll all sessions together) ──────────────────
log "Waiting up to ${HANDOFF_TIMEOUT}s for handoffs..."
DEADLINE=$(( TRIGGER_EPOCH + HANDOFF_TIMEOUT ))

while [[ $(date +%s) -lt $DEADLINE ]]; do
    pending=0
    for session in "${sessions_to_swap[@]}"; do
        [[ -f "$LOCK_DIR/handoff-${session}" ]] && continue   # already found

        found=""
        for f in "$HANDOFF_DIR"/${session}-*.md; do
            [[ -f "$f" ]] || continue
            mod=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
            age=$(( TRIGGER_EPOCH - mod ))
            if [[ $age -le 60 && $age -ge -300 ]]; then
                found="$f"
                break
            fi
        done

        if [[ -n "$found" ]]; then
            echo "$found" > "$LOCK_DIR/handoff-${session}"
            log "Got handoff: $session → $found"
        else
            pending=$(( pending + 1 ))
        fi
    done
    [[ $pending -eq 0 ]] && break
    sleep 10
done

# Mark timed-out sessions
for session in "${sessions_to_swap[@]}"; do
    if [[ ! -f "$LOCK_DIR/handoff-${session}" ]]; then
        echo "TIMEOUT" > "$LOCK_DIR/handoff-${session}"
        log "TIMEOUT: No handoff from $session — proceeding without"
    fi
done

# ─── Helper: extract continuation prompt ──────────────────────────────────────
extract_continuation() {
    local file="$1"
    python3 -c "
import re
try:
    content = open('$file').read()
    m = re.search(r'##.*[Cc]ontinuation.*?\n(.*?)(?=\n##|\Z)', content, re.DOTALL)
    if m:
        prompt = m.group(1).strip()
        prompt = re.sub(r'^\`\`\`.*\n?', '', prompt, flags=re.MULTILINE)
        prompt = re.sub(r'^\`\`\`\s*$', '', prompt, flags=re.MULTILINE)
        print(prompt.strip())
    else:
        print('')
except:
    print('')
" 2>/dev/null
}

# ─── Phase 3+4: Kill → Restart → Inject (sequential) ─────────────────────────
success_count=0
fail_count=0

for session in "${sessions_to_swap[@]}"; do
    handoff_result=$(cat "$LOCK_DIR/handoff-${session}" 2>/dev/null || echo "TIMEOUT")
    log "Processing $session (handoff: $handoff_result)"

    # Get working directory: metadata > tmux pane path > home
    work_dir="$HOME"
    meta="$SESSIONS_DIR/$session"
    if [[ -f "$meta" ]]; then
        meta_cwd=$(python3 -c "
import json
try:
    d=json.load(open('$meta'))
    print(d.get('cwd','') or '')
except: print('')
" 2>/dev/null)
        [[ -n "$meta_cwd" && -d "$meta_cwd" ]] && work_dir="$meta_cwd"
    fi
    if [[ "$work_dir" == "$HOME" ]]; then
        pane_dir=$(tmux display-message -t "$session" -p '#{pane_current_path}' 2>/dev/null || echo "")
        [[ -n "$pane_dir" && -d "$pane_dir" ]] && work_dir="$pane_dir"
    fi

    # Kill
    log "  Kill: $session"
    rm -f "$HANDOFF_DIR/.team-active-${session}" 2>/dev/null
    tmux kill-session -t "$session" 2>/dev/null || true
    sleep 2

    # Start new session on TO_ACCOUNT
    log "  Start: $session on account $TO_ACCOUNT ($TO_TAG) in $work_dir"

    # ns (account 1): do NOT set CLAUDE_CONFIG_DIR — uses ~/.claude.json (home level) for auth
    # nl (account 2): set CLAUDE_CONFIG_DIR=~/.claude-account2
    if [[ "$TO_CONFIG" == "UNSET" ]]; then
        if ! tmux new-session -d -s "$session" -c "$work_dir" 2>/dev/null; then
            log "  ERROR: could not create tmux session $session"
            fail_count=$(( fail_count + 1 ))
            continue
        fi
    else
        if ! tmux new-session -d -s "$session" -c "$work_dir" -e "CLAUDE_CONFIG_DIR=$TO_CONFIG" 2>/dev/null; then
            log "  ERROR: could not create tmux session $session"
            fail_count=$(( fail_count + 1 ))
            continue
        fi
    fi

    # Enable logging
    tmux pipe-pane -t "$session" "exec $LOG_PIPE '$session'" 2>/dev/null || true

    # Build launch prefix — ns: unset CLAUDE_CONFIG_DIR; nl: set it
    if [[ "$TO_CONFIG" == "UNSET" ]]; then
        LAUNCH_PREFIX="unset CLAUDE_CONFIG_DIR &&"
    else
        LAUNCH_PREFIX="CLAUDE_CONFIG_DIR=$TO_CONFIG"
    fi

    # Start claude with appropriate system prompt
    if [[ "$session" == "claude-0" && -f "$COORDINATOR_MD" ]]; then
        tmux send-keys -t "$session" "$LAUNCH_PREFIX claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $COORDINATOR_MD)\""
    elif [[ -f "$WORKER_MD" ]]; then
        tmux send-keys -t "$session" "$LAUNCH_PREFIX claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $WORKER_MD)\""
    else
        tmux send-keys -t "$session" "$LAUNCH_PREFIX claude --dangerously-skip-permissions"
    fi
    tmux send-keys -t "$session" Enter

    # Update account tracking
    echo "$TO_ACCOUNT" > "/tmp/claude-account-${session}"
    tmux set-environment -t "$session" CLAUDE_ACCOUNT "$TO_ACCOUNT" 2>/dev/null || true

    # Wait for claude to boot (up to 45s)
    booted=false
    i=0
    while [[ $i -lt 45 ]]; do
        out=$(tmux capture-pane -t "$session" -p 2>/dev/null || echo "")
        if echo "$out" | grep -qiE 'send|>|claude|thinking|percolating'; then
            booted=true
            break
        fi
        sleep 1
        i=$(( i + 1 ))
    done
    [[ "$booted" == "false" ]] && log "  WARN: $session may not have booted cleanly" && sleep 5

    # Build continuation injection
    if [[ "$handoff_result" != "TIMEOUT" && -f "$handoff_result" ]]; then
        continuation=$(extract_continuation "$handoff_result")
        inject_body="🔄 **ACCOUNT SWAP COMPLETE — Now on ${TO_TAG}**

Moved from **${FROM_TAG}** → **${TO_TAG}** (reason: ${REASON})
Handoff file: \`${handoff_result}\`

## Read your handoff first
\`\`\`bash
cat ${handoff_result}
\`\`\`

## Continue from here
${continuation:-*(no continuation prompt found — read handoff manually)*}

Check context before starting tasks:
\`\`\`bash
~/.claude/scripts/check-context.sh
\`\`\`"
    else
        inject_body="🔄 **ACCOUNT SWAP COMPLETE — Now on ${TO_TAG}**

Moved from **${FROM_TAG}** → **${TO_TAG}** (reason: ${REASON})
No handoff was received (timeout or crash).

Check for recent handoffs:
\`\`\`bash
ls -lt ~/.claude/handoffs/${session}-*.md 2>/dev/null | head -5
\`\`\`

Resume from the most recent one, or start fresh if none exists."
    fi

    sleep 3
    "$INJECT" "$session" "$inject_body" &>/dev/null || log "  WARN: continuation inject failed for $session"

    # Update session metadata
    if [[ -f "$meta" ]]; then
        python3 -c "
import json, os
meta = '$meta'
try:
    d = json.load(open(meta))
except:
    d = {}
d.update({'account': $TO_ACCOUNT, 'cwd': '$work_dir', 'status': 'active', 'restarted_from': 'auto-swap'})
json.dump(d, open(meta, 'w'), indent=2)
" 2>/dev/null || true
    fi

    success_count=$(( success_count + 1 ))
    log "  Done: $session → $TO_TAG"
done

# ─── Update active-account ────────────────────────────────────────────────────
echo "$TO_ACCOUNT" > "$AM_DIR/active-account"

# ─── Final notifications ──────────────────────────────────────────────────────
log "Swap complete: ${success_count} moved to $TO_TAG, ${fail_count} failed"

"$TTS_SCRIPT" "Account swap done. ${success_count} sessions now on ${TO_TAG}." &>/dev/null &
"$TG_SCRIPT" --session "auto-swap" "✅ <b>Account Swap Complete</b>

🔄 ${FROM_TAG} → ${TO_TAG}
✅ <b>Moved:</b> ${success_count} sessions
❌ <b>Failed:</b> ${fail_count} sessions
📋 <b>Sessions:</b> ${sessions_to_swap[*]}
💡 <i>All agents have continuation prompts injected.</i>" &>/dev/null &
