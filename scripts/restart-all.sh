#!/bin/bash
# restart-all.sh - Graceful restart of all Claude Code sessions
# Usage:
#   restart-all.sh [--graceful]    Handoff, kill, restart with continuity (default)
#   restart-all.sh --force         Kill all immediately, restart with best-effort handoffs
#   restart-all.sh --shutdown      Handoff and kill (no restart), save state for later
#   restart-all.sh --resume        Restart from saved state file
#   restart-all.sh --status        Show current state of all sessions
#
# Options:
#   --timeout <seconds>   Override handoff wait timeout
#   --reason <text>       Reason for restart (included in notifications)
#   --dry-run             Show what would happen without doing it

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOFF_DIR="$HOME/.claude/handoffs"
CONFIG_FILE="$HOME/.claude/handoff-config.json"
STATE_FILE="$HOME/.claude/restart-state.json"
INJECT_SCRIPT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"
SEND_SUMMARY="$HOME/.claude/telegram-orchestrator/send-summary.sh"
TTS_WRITE="$HOME/.claude/scripts/tts-write.sh"
LOG_PIPE="$HOME/.claude/scripts/tmux-log-pipe.sh"
COORDINATOR_MD="$HOME/.claude/telegram-orchestrator/coordinator-claude.md"
SESSIONS_DIR="$HOME/.claude/telegram-orchestrator/sessions"
LOG_FILE="$HANDOFF_DIR/restart-all.log"

MODE="graceful"
TIMEOUT=""
REASON=""
DRY_RUN=false

WORKER_SESSIONS=()
COORDINATOR_SESSIONS=()
SKIPPED_SESSIONS=()
ALL_SESSIONS=()
EXCLUDED_SESSIONS=""

# --- Helpers ---

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

usage() {
    head -13 "$0" | tail -12 | sed 's/^# //'
    exit 1
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        EXCLUDED_SESSIONS=$(jq -r '.excluded_sessions // [] | .[]' "$CONFIG_FILE" 2>/dev/null)
        local config_timeout
        config_timeout=$(jq -r '.handoff_wait_seconds // 120' "$CONFIG_FILE" 2>/dev/null)
        [ -z "$TIMEOUT" ] && TIMEOUT="$config_timeout"
    fi
    [ -z "$TIMEOUT" ] && TIMEOUT=120
}

is_excluded() {
    local session="$1"
    echo "$EXCLUDED_SESSIONS" | grep -qx "$session" 2>/dev/null
}

is_coordinator() {
    [[ "$1" =~ ^claude-0(-acc[0-9])?$ ]]
}

get_account() {
    if [[ "$1" == *-acc2 ]]; then echo "2"; else echo "1"; fi
}

get_working_dir() {
    tmux display-message -t "$1" -p '#{pane_current_path}' 2>/dev/null || echo "$HOME"
}

is_claude_running() {
    local pane_content
    pane_content=$(tmux capture-pane -t "$1" -p -S -10 2>/dev/null)
    if echo "$pane_content" | grep -qE "(esc to interrupt|bypass permissions|↵ send|thinking|Percolating|Leavening|Misting|Reasoning|Reading|Writing|Claude Code)"; then
        return 0
    fi
    return 1
}

has_active_teams() {
    local session="$1"
    [ -f "$HANDOFF_DIR/.team-active-$session" ] && return 0
    local pane_pid claude_pid child_count
    pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$pane_pid" ]; then
        claude_pid=$(pgrep -P "$pane_pid" -f "claude" 2>/dev/null | head -1)
        if [ -n "$claude_pid" ]; then
            child_count=$(pgrep -P "$claude_pid" 2>/dev/null | wc -l | tr -d ' ')
            [ "$child_count" -gt 2 ] && return 0
        fi
    fi
    return 1
}

find_latest_handoff() {
    local session="$1"
    local since_epoch="${2:-0}"
    local file
    for file in $(ls -t "$HANDOFF_DIR"/${session}-*.md 2>/dev/null); do
        [ -f "$file" ] || continue
        if [ "$since_epoch" -gt 0 ]; then
            local mod_epoch
            mod_epoch=$(stat -f %m "$file" 2>/dev/null || echo "0")
            if [ "$mod_epoch" -ge "$since_epoch" ]; then
                echo "$file"
                return 0
            fi
        else
            echo "$file"
            return 0
        fi
    done
}

extract_continuation() {
    local handoff_file="$1"
    local continuation
    continuation=$(grep -A 100 "## .*Continuation Prompt" "$handoff_file" 2>/dev/null | grep -A 100 '```' | head -50 | tail -n +2 | grep -B 100 '```' | head -n -1)
    if [ -z "$continuation" ]; then
        continuation="Continue from where previous session left off. Read handoff: cat $handoff_file"
    fi
    echo "$continuation"
}

# --- Discovery ---

discover_sessions() {
    WORKER_SESSIONS=()
    COORDINATOR_SESSIONS=()
    SKIPPED_SESSIONS=()

    while IFS= read -r session; do
        [[ "$session" =~ ^claude- ]] || continue
        if is_excluded "$session"; then
            SKIPPED_SESSIONS+=("$session")
            continue
        fi
        if is_coordinator "$session"; then
            COORDINATOR_SESSIONS+=("$session")
        else
            WORKER_SESSIONS+=("$session")
        fi
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort)

    ALL_SESSIONS=("${WORKER_SESSIONS[@]}" "${COORDINATOR_SESSIONS[@]}")
}

# --- Handoff injection + wait (runs per-session, backgroundable) ---

inject_and_wait_handoff() {
    local session="$1"
    local timeout="$2"
    local trigger_epoch
    trigger_epoch=$(date +%s)

    if ! is_claude_running "$session"; then
        echo "CRASHED"
        return 1
    fi

    local effective_timeout="$timeout"
    if has_active_teams "$session"; then
        effective_timeout=600
    fi

    local reason_line=""
    [ -n "$REASON" ] && reason_line="**Reason:** $REASON"

    "$INJECT_SCRIPT" "$session" "🔄 **RESTART-ALL: Handoff requested**
${reason_line}

All Claude sessions are being restarted. Finalize your handoff NOW:
1. Add final progress entry to your handoff file
2. Fill the 'Continuation Prompt' section completely
3. If no handoff file exists, create one: ~/.claude/handoffs/${session}-\$(date '+%Y-%m-%d-%H%M').md

You have ${effective_timeout} seconds." 2>/dev/null

    local waited=0
    while [ $waited -lt "$effective_timeout" ]; do
        for file in "$HANDOFF_DIR"/${session}-*.md; do
            [ -f "$file" ] || continue
            local fname mod_epoch mod_age file_ts file_date file_epoch time_diff
            fname=$(basename "$file" .md)
            file_ts=$(echo "$fname" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$')

            # Filename timestamp check
            if [ -n "$file_ts" ]; then
                file_date=$(echo "$file_ts" | sed 's/-\([0-9]\{4\}\)$/ \1/' | sed 's/\(..\)$/:\1/')
                file_epoch=$(date -j -f "%Y-%m-%d %H:%M" "$file_date" +%s 2>/dev/null || echo "0")
                time_diff=$((file_epoch - trigger_epoch))
                if [ "$time_diff" -ge -60 ]; then
                    echo "$file"
                    return 0
                fi
            fi

            # Modification time check
            mod_epoch=$(stat -f %m "$file" 2>/dev/null || echo "0")
            mod_age=$((trigger_epoch - mod_epoch))
            if [ "$mod_age" -le 300 ] && [ "$mod_age" -ge -300 ]; then
                echo "$file"
                return 0
            fi
        done

        sleep 10
        waited=$((waited + 10))
    done

    # Final scan (race condition fix)
    for file in "$HANDOFF_DIR"/${session}-*.md; do
        [ -f "$file" ] || continue
        local mod_epoch mod_age
        mod_epoch=$(stat -f %m "$file" 2>/dev/null || echo "0")
        mod_age=$((trigger_epoch - mod_epoch))
        if [ "$mod_age" -le 300 ] && [ "$mod_age" -ge -300 ]; then
            echo "$file"
            return 0
        fi
    done

    echo "TIMEOUT"
    return 1
}

# --- Kill session ---

kill_session() {
    local session="$1"
    log "  Kill: $session"
    rm -f "$HANDOFF_DIR/.team-active-$session"
    tmux kill-session -t "$session" 2>/dev/null || true
    sleep 1
}

# --- Restart session ---

restart_session() {
    local session="$1"
    local handoff_file="$2"
    local working_dir="$3"
    local account
    account=$(get_account "$session")

    [ -z "$working_dir" ] || [ ! -d "$working_dir" ] && working_dir="$HOME"

    log "  Start: $session (acc=$account, dir=$working_dir)"

    # Create tmux session with correct account
    if [ "$account" = "2" ]; then
        tmux new-session -d -s "$session" -c "$working_dir" -e "CLAUDE_CONFIG_DIR=$HOME/.claude-account2"
    else
        tmux new-session -d -s "$session" -c "$working_dir"
    fi

    # Enable session logging
    tmux pipe-pane -t "$session" "exec $LOG_PIPE '$session'" 2>/dev/null || true

    # Start Claude with appropriate system prompt
    local WORKER_MD="$HOME/.claude/telegram-orchestrator/worker-claude.md"
    if is_coordinator "$session" && [ -f "$COORDINATOR_MD" ]; then
        tmux send-keys -t "$session" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $COORDINATOR_MD)\""
    elif [ -f "$WORKER_MD" ]; then
        tmux send-keys -t "$session" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $WORKER_MD)\""
    else
        tmux send-keys -t "$session" "claude --dangerously-skip-permissions"
    fi
    tmux send-keys -t "$session" Enter
    sleep 5

    # Inject continuation prompt
    if [ -n "$handoff_file" ] && [ -f "$handoff_file" ]; then
        local continuation
        continuation=$(extract_continuation "$handoff_file")

        "$INJECT_SCRIPT" "$session" "🔄 **RESTART-ALL COMPLETE - Fresh Instance**

Previous session was restarted.${REASON:+
**Reason:** $REASON}
Handoff file: $handoff_file

## Read Your Handoff First
\`\`\`bash
cat $handoff_file
\`\`\`

## Your Continuation
$continuation

## Context Awareness (CRITICAL)
**Threshold is 50%.** Check context BEFORE starting each new task:
\`\`\`bash
~/.claude/scripts/check-context.sh
\`\`\`

**Start now: 1) Read handoff, 2) Create your handoff file, 3) Continue work.**" 2>/dev/null
    fi

    # Update session metadata
    local role="worker"
    is_coordinator "$session" && role="coordinator"
    mkdir -p "$SESSIONS_DIR"
    cat > "$SESSIONS_DIR/$session" << METAEOF
{
  "name": "$session",
  "started": "$(date -Iseconds)",
  "cwd": "$working_dir",
  "role": "$role",
  "account": $account,
  "status": "active",
  "restarted_from": "restart-all"
}
METAEOF
}

# --- Notifications ---

send_notifications() {
    local mode="$1" total="$2" success="$3" failed="$4"
    local emoji label
    case "$mode" in
        graceful) emoji="🔄"; label="Graceful Restart" ;;
        force)    emoji="⚡"; label="Force Restart" ;;
        shutdown) emoji="🛑"; label="Shutdown" ;;
        resume)   emoji="▶️";  label="Resume" ;;
    esac

    "$SEND_SUMMARY" --session "restart-all" "${emoji} <b>${label} Complete</b>

📊 <b>Sessions:</b> ${total} total
✅ <b>Handoffs:</b> ${success} successful
❌ <b>No handoff:</b> ${failed}
${REASON:+💡 <b>Reason:</b> ${REASON}}" 2>/dev/null || true

    "$TTS_WRITE" "${label} complete. ${total} sessions, ${success} with handoff." 2>/dev/null || true
}

# --- MODE: status ---

do_status() {
    discover_sessions

    echo "=== Claude Session Status ==="
    echo ""
    printf "%-20s %-10s %-8s %-6s %-45s\n" "SESSION" "STATE" "ACCOUNT" "TEAMS" "LATEST HANDOFF"
    printf "%-20s %-10s %-8s %-6s %-45s\n" "-------" "-----" "-------" "-----" "--------------"

    for session in "${ALL_SESSIONS[@]}"; do
        local state="unknown" account teams="no" handoff_name="none"
        account="acc$(get_account "$session")"

        if is_claude_running "$session"; then
            local pane
            pane=$(tmux capture-pane -t "$session" -p -S -5 2>/dev/null)
            if echo "$pane" | grep -qE "(esc to interrupt|thinking|Percolating|Reasoning)"; then
                state="thinking"
            else
                state="idle"
            fi
        else
            state="crashed"
        fi

        has_active_teams "$session" && teams="YES"

        local latest
        latest=$(find_latest_handoff "$session")
        if [ -n "$latest" ]; then
            local mod_epoch now_epoch age_min
            mod_epoch=$(stat -f %m "$latest" 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            age_min=$(( (now_epoch - mod_epoch) / 60 ))
            handoff_name="$(basename "$latest") (${age_min}m ago)"
        fi

        printf "%-20s %-10s %-8s %-6s %-45s\n" "$session" "$state" "$account" "$teams" "$handoff_name"
    done

    [ ${#SKIPPED_SESSIONS[@]} -gt 0 ] && echo "" && echo "Excluded: ${SKIPPED_SESSIONS[*]}"

    local others
    others=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v '^claude-' | tr '\n' ', ' | sed 's/,$//')
    [ -n "$others" ] && echo "" && echo "Non-Claude: $others"
}

# --- MODE: graceful ---

do_graceful() {
    discover_sessions
    local total=${#ALL_SESSIONS[@]}
    [ "$total" -eq 0 ] && { log "No claude sessions found."; return 0; }

    log "=== GRACEFUL RESTART: $total sessions ==="
    [ -n "$REASON" ] && log "Reason: $REASON"

    # Phase 1: Capture working dirs + inject handoffs in parallel
    log "Phase 1: Requesting handoffs..."
    declare -A HANDOFF_RESULTS SESSION_CWDS HANDOFF_PIDS

    for session in "${WORKER_SESSIONS[@]}"; do
        SESSION_CWDS[$session]=$(get_working_dir "$session")
        inject_and_wait_handoff "$session" "$TIMEOUT" > "/tmp/restart-all-${session}.result" 2>&1 &
        HANDOFF_PIDS[$session]=$!
        log "  Injected: $session (PID ${HANDOFF_PIDS[$session]})"
    done

    sleep 5

    for session in "${COORDINATOR_SESSIONS[@]}"; do
        SESSION_CWDS[$session]=$(get_working_dir "$session")
        inject_and_wait_handoff "$session" "$TIMEOUT" > "/tmp/restart-all-${session}.result" 2>&1 &
        HANDOFF_PIDS[$session]=$!
        log "  Injected: $session (coordinator, PID ${HANDOFF_PIDS[$session]})"
    done

    # Phase 2: Wait for all
    log "Phase 2: Waiting for handoffs (timeout: ${TIMEOUT}s)..."
    local completed=0 failed=0

    for session in "${ALL_SESSIONS[@]}"; do
        wait "${HANDOFF_PIDS[$session]}" 2>/dev/null || true
        local result
        result=$(cat "/tmp/restart-all-${session}.result" 2>/dev/null | tail -1)
        rm -f "/tmp/restart-all-${session}.result"

        if [ -f "$result" ] 2>/dev/null; then
            HANDOFF_RESULTS[$session]="$result"
            completed=$((completed + 1))
            log "  $session: Handoff OK → $(basename "$result")"
        else
            HANDOFF_RESULTS[$session]=""
            failed=$((failed + 1))
            log "  $session: No handoff ($result)"
            # Try recent fallback
            local recent
            recent=$(find_latest_handoff "$session" $(($(date +%s) - 600)))
            if [ -n "$recent" ]; then
                HANDOFF_RESULTS[$session]="$recent"
                log "  $session: Using recent fallback → $(basename "$recent")"
            fi
        fi
    done

    log "Phase 2 done: $completed handoffs, $failed failed"

    # Phase 3: Kill (workers first, coordinator last)
    log "Phase 3: Killing sessions..."
    for session in "${WORKER_SESSIONS[@]}"; do kill_session "$session"; done
    sleep 2
    for session in "${COORDINATOR_SESSIONS[@]}"; do kill_session "$session"; done

    # Phase 4: Restart (coordinator first, workers after)
    log "Phase 4: Restarting..."
    for session in "${COORDINATOR_SESSIONS[@]}"; do
        restart_session "$session" "${HANDOFF_RESULTS[$session]:-}" "${SESSION_CWDS[$session]:-$HOME}"
        sleep 3
    done
    for session in "${WORKER_SESSIONS[@]}"; do
        restart_session "$session" "${HANDOFF_RESULTS[$session]:-}" "${SESSION_CWDS[$session]:-$HOME}"
        sleep 2
    done

    send_notifications "graceful" "$total" "$completed" "$failed"
    log "=== GRACEFUL RESTART COMPLETE ==="
}

# --- MODE: force ---

do_force() {
    discover_sessions
    local total=${#ALL_SESSIONS[@]}
    [ "$total" -eq 0 ] && { log "No claude sessions found."; return 0; }

    log "=== FORCE RESTART: $total sessions ==="
    [ -n "$REASON" ] && log "Reason: $REASON"

    declare -A SESSION_CWDS HANDOFF_RESULTS
    local ten_min_ago=$(($(date +%s) - 600))

    for session in "${ALL_SESSIONS[@]}"; do
        SESSION_CWDS[$session]=$(get_working_dir "$session")
        HANDOFF_RESULTS[$session]=$(find_latest_handoff "$session" "$ten_min_ago")
    done

    log "Phase 1: Force killing..."
    for session in "${WORKER_SESSIONS[@]}"; do kill_session "$session"; done
    for session in "${COORDINATOR_SESSIONS[@]}"; do kill_session "$session"; done
    sleep 2

    log "Phase 2: Restarting..."
    for session in "${COORDINATOR_SESSIONS[@]}"; do
        restart_session "$session" "${HANDOFF_RESULTS[$session]:-}" "${SESSION_CWDS[$session]:-$HOME}"
        sleep 3
    done
    for session in "${WORKER_SESSIONS[@]}"; do
        restart_session "$session" "${HANDOFF_RESULTS[$session]:-}" "${SESSION_CWDS[$session]:-$HOME}"
        sleep 2
    done

    local handoff_count=0
    for session in "${ALL_SESSIONS[@]}"; do
        [ -n "${HANDOFF_RESULTS[$session]:-}" ] && handoff_count=$((handoff_count + 1))
    done

    send_notifications "force" "$total" "$handoff_count" "$((total - handoff_count))"
    log "=== FORCE RESTART COMPLETE ==="
}

# --- MODE: shutdown ---

do_shutdown() {
    discover_sessions
    local total=${#ALL_SESSIONS[@]}
    [ "$total" -eq 0 ] && { log "No claude sessions found."; return 0; }

    log "=== SHUTDOWN: $total sessions ==="
    [ -n "$REASON" ] && log "Reason: $REASON"

    # Phase 1: Request handoffs in parallel
    log "Phase 1: Requesting handoffs..."
    declare -A HANDOFF_RESULTS SESSION_CWDS HANDOFF_PIDS

    for session in "${ALL_SESSIONS[@]}"; do
        SESSION_CWDS[$session]=$(get_working_dir "$session")
        inject_and_wait_handoff "$session" "$TIMEOUT" > "/tmp/restart-all-${session}.result" 2>&1 &
        HANDOFF_PIDS[$session]=$!
    done

    local completed=0
    for session in "${ALL_SESSIONS[@]}"; do
        wait "${HANDOFF_PIDS[$session]}" 2>/dev/null || true
        local result
        result=$(cat "/tmp/restart-all-${session}.result" 2>/dev/null | tail -1)
        rm -f "/tmp/restart-all-${session}.result"

        if [ -f "$result" ] 2>/dev/null; then
            HANDOFF_RESULTS[$session]="$result"
            completed=$((completed + 1))
        else
            HANDOFF_RESULTS[$session]=$(find_latest_handoff "$session" $(($(date +%s) - 600)))
        fi
    done

    # Phase 2: Save state
    log "Phase 2: Saving state to $STATE_FILE..."
    local sessions_json="["
    local first=true
    for session in "${ALL_SESSIONS[@]}"; do
        local account handoff cwd role
        account=$(get_account "$session")
        handoff="${HANDOFF_RESULTS[$session]:-}"
        cwd="${SESSION_CWDS[$session]:-$HOME}"
        role="worker"
        is_coordinator "$session" && role="coordinator"

        [ "$first" = true ] && first=false || sessions_json+=","
        sessions_json+=$(jq -n \
            --arg name "$session" \
            --arg cwd "$cwd" \
            --arg account "$account" \
            --arg handoff "$handoff" \
            --arg role "$role" \
            '{name: $name, cwd: $cwd, account: ($account | tonumber), handoff: (if $handoff == "" then null else $handoff end), role: $role}')
    done
    sessions_json+="]"

    jq -n \
        --arg timestamp "$(date -Iseconds)" \
        --arg reason "$REASON" \
        --argjson sessions "$sessions_json" \
        '{timestamp: $timestamp, reason: $reason, sessions: $sessions}' > "$STATE_FILE"

    log "  State saved: $total sessions"

    # Phase 3: Kill all
    log "Phase 3: Killing sessions..."
    for session in "${WORKER_SESSIONS[@]}"; do kill_session "$session"; done
    sleep 2
    for session in "${COORDINATOR_SESSIONS[@]}"; do kill_session "$session"; done

    send_notifications "shutdown" "$total" "$completed" "$((total - completed))"
    log "=== SHUTDOWN COMPLETE. Resume with: restart-all.sh --resume ==="
}

# --- MODE: resume ---

do_resume() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "No state file at $STATE_FILE. Use --graceful or --force instead."
        exit 1
    fi

    local state_ts session_count
    state_ts=$(jq -r '.timestamp' "$STATE_FILE")
    session_count=$(jq '.sessions | length' "$STATE_FILE")

    log "=== RESUME from $state_ts ($session_count sessions) ==="

    # Restart coordinators first
    local coordinators workers
    coordinators=$(jq -r '.sessions[] | select(.role == "coordinator") | .name' "$STATE_FILE")
    workers=$(jq -r '.sessions[] | select(.role != "coordinator") | .name' "$STATE_FILE")

    for session in $coordinators; do
        if tmux has-session -t "$session" 2>/dev/null; then
            log "  $session already exists, skipping"
            continue
        fi
        local cwd handoff
        cwd=$(jq -r --arg s "$session" '.sessions[] | select(.name == $s) | .cwd' "$STATE_FILE")
        handoff=$(jq -r --arg s "$session" '.sessions[] | select(.name == $s) | .handoff // ""' "$STATE_FILE")
        restart_session "$session" "$handoff" "$cwd"
        sleep 3
    done

    for session in $workers; do
        if tmux has-session -t "$session" 2>/dev/null; then
            log "  $session already exists, skipping"
            continue
        fi
        local cwd handoff
        cwd=$(jq -r --arg s "$session" '.sessions[] | select(.name == $s) | .cwd' "$STATE_FILE")
        handoff=$(jq -r --arg s "$session" '.sessions[] | select(.name == $s) | .handoff // ""' "$STATE_FILE")
        restart_session "$session" "$handoff" "$cwd"
        sleep 2
    done

    mv "$STATE_FILE" "${STATE_FILE%.json}-$(date '+%Y%m%d-%H%M%S').resumed.json"

    send_notifications "resume" "$session_count" "$session_count" "0"
    log "=== RESUME COMPLETE ==="
}

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --graceful)  MODE="graceful"; shift ;;
            --force)     MODE="force"; shift ;;
            --shutdown)  MODE="shutdown"; shift ;;
            --resume)    MODE="resume"; shift ;;
            --status)    MODE="status"; shift ;;
            --timeout)   TIMEOUT="$2"; shift 2 ;;
            --reason)    REASON="$2"; shift 2 ;;
            --dry-run)   DRY_RUN=true; shift ;;
            -h|--help)   usage ;;
            *)           echo "Unknown: $1"; usage ;;
        esac
    done
}

# --- Main ---

main() {
    mkdir -p "$HANDOFF_DIR"
    parse_args "$@"
    load_config

    log "restart-all.sh mode=$MODE"

    if [ "$DRY_RUN" = true ]; then
        discover_sessions
        echo "[DRY RUN] Mode: $MODE"
        echo "Workers: ${WORKER_SESSIONS[*]:-none}"
        echo "Coordinators: ${COORDINATOR_SESSIONS[*]:-none}"
        echo "Excluded: ${SKIPPED_SESSIONS[*]:-none}"
        echo "Timeout: ${TIMEOUT}s"
        [ -n "$REASON" ] && echo "Reason: $REASON"
        exit 0
    fi

    case "$MODE" in
        status)   do_status ;;
        graceful) do_graceful ;;
        force)    do_force ;;
        shutdown) do_shutdown ;;
        resume)   do_resume ;;
    esac
}

main "$@"
