#!/bin/bash
# Watchdog v4.0 - Unified watchdog for Claude instances
#
# Usage:
#   watchdog.sh start [instances...]  - Start watching (default: reminder-only mode)
#   watchdog.sh stop                  - Stop watchdog
#   watchdog.sh status                - Show status
#   watchdog.sh add <instance>        - Add instance to watch list
#   watchdog.sh remove <instance>     - Remove from watch list
#   watchdog.sh list                  - List watched instances
#   watchdog.sh daemon                - Run daemon loop (internal)

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SCRIPT_DIR/watchdog-state"
INSTANCES_FILE="$STATE_DIR/instances"
PID_FILE="$STATE_DIR/watchdog.pid"
LOG_FILE="$SCRIPT_DIR/logs/watchdog.log"

# Timing configs
CHECK_INTERVAL=30
FORCE_PUSH_INTERVAL=300      # 5 minutes
REMINDER_INTERVAL=1800       # 30 minutes
REPORT_INTERVAL=1800         # 30 minutes

mkdir -p "$STATE_DIR" "$SCRIPT_DIR/logs"

#
# Utility functions
#

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_telegram() {
    "$SCRIPT_DIR/send-summary.sh" --session "watchdog" "$1" 2>/dev/null
}

get_watched_instances() {
    if [[ -f "$INSTANCES_FILE" ]]; then
        cat "$INSTANCES_FILE" | tr '\n' ' ' | xargs
    fi
}

get_all_claude_instances() {
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -E "^claude-[0-9]+-acc[12]$|^claude-[0-9]+$" | tr '\n' ' '
}

#
# Circuit Breaker (RALPH-style)
# Prevents runaway sessions by detecting lack of progress
#

CB_STATE_DIR="$STATE_DIR/circuits"
CB_NO_PROGRESS_THRESHOLD=3      # Open circuit after 3 cycles with no progress
CB_COMPLETION_THRESHOLD=5       # Force exit after 5 consecutive completion indicators

mkdir -p "$CB_STATE_DIR"

cb_get_no_progress() {
    local session=$1
    cat "$CB_STATE_DIR/${session}.no_progress" 2>/dev/null || echo "0"
}

cb_get_completions() {
    local session=$1
    cat "$CB_STATE_DIR/${session}.completions" 2>/dev/null || echo "0"
}

cb_is_open() {
    local session=$1
    [[ -f "$CB_STATE_DIR/${session}.open" ]]
}

cb_open() {
    local session=$1
    local reason=$2
    touch "$CB_STATE_DIR/${session}.open"
    echo "$(date '+%Y-%m-%d %H:%M:%S') OPEN: $reason" >> "$CB_STATE_DIR/${session}.history"
    log "[$session] Circuit OPEN: $reason"
    send_telegram "🔴 <b>Circuit Breaker OPEN</b>

<b>Session:</b> $session
<b>Reason:</b> $reason

Session halted. Use /watchdog reset $session to resume."
}

cb_reset() {
    local session=$1
    rm -f "$CB_STATE_DIR/${session}.open"
    rm -f "$CB_STATE_DIR/${session}.no_progress"
    rm -f "$CB_STATE_DIR/${session}.completions"
    echo "$(date '+%Y-%m-%d %H:%M:%S') RESET" >> "$CB_STATE_DIR/${session}.history"
    log "[$session] Circuit RESET"
}

cb_record_progress() {
    local session=$1
    local had_progress=$2  # true/false

    # Skip coordinator - it doesn't do dev work (matches claude-0, claude-0-acc1, claude-0-acc2)
    [[ "$session" =~ ^claude-0(-acc[12])?$ ]] && return 0

    local no_progress=$(cb_get_no_progress "$session")

    if [[ "$had_progress" == "true" ]]; then
        # Reset counter on progress
        echo "0" > "$CB_STATE_DIR/${session}.no_progress"
    else
        # Increment no-progress counter
        no_progress=$((no_progress + 1))
        echo "$no_progress" > "$CB_STATE_DIR/${session}.no_progress"

        if [[ $no_progress -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
            cb_open "$session" "No progress for $no_progress cycles"
            return 1
        fi
    fi
    return 0
}

cb_record_completion() {
    local session=$1
    local exit_signal=$2  # true/false/none

    # Skip coordinator (matches claude-0, claude-0-acc1, claude-0-acc2)
    [[ "$session" =~ ^claude-0(-acc[12])?$ ]] && return 0

    local completions=$(cb_get_completions "$session")

    if [[ "$exit_signal" == "true" ]]; then
        # Task genuinely complete - notify but don't open circuit
        log "[$session] EXIT_SIGNAL: true - task complete"
        send_telegram "✅ <b>Task Complete</b>

<b>Session:</b> $session
EXIT_SIGNAL received. Session finished its work."
        cb_reset "$session"
        return 0
    elif [[ "$exit_signal" == "false" ]]; then
        # Explicitly not done - reset completion counter
        echo "0" > "$CB_STATE_DIR/${session}.completions"
    else
        # No signal but seeing completion patterns - increment
        completions=$((completions + 1))
        echo "$completions" > "$CB_STATE_DIR/${session}.completions"

        if [[ $completions -ge $CB_COMPLETION_THRESHOLD ]]; then
            cb_open "$session" "Stuck in completion loop ($completions indicators without EXIT_SIGNAL)"
            return 1
        fi
    fi
    return 0
}

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    tmux has-session -t watchdog 2>/dev/null && return 0
    return 1
}

#
# Account Management & Rate Limit Detection
#

ACCOUNT_DIR="$HOME/.claude/account-manager"

get_active_account() {
    cat "$ACCOUNT_DIR/active-account" 2>/dev/null || echo "1"
}

get_session_account() {
    local session=$1
    local session_file="$SCRIPT_DIR/sessions/$session"
    if [[ -f "$session_file" ]]; then
        jq -r '.account // 1' "$session_file" 2>/dev/null || echo "1"
    else
        echo "1"
    fi
}

detect_rate_limit() {
    local output="$1"

    # Hard limit messages - actual Claude Code messages (immediate migration needed)
    if echo "$output" | grep -qE "You've hit your limit|You're out of extra usage"; then
        echo "hard_limit"
        return 0
    fi

    # Legacy patterns (keep for backwards compatibility)
    if echo "$output" | grep -qiE "rate limit|usage limit|out of capacity|try again later|exceeded.*limit|too many requests|reached.*limit|limit reached|quota exceeded"; then
        echo "hard_limit"
        return 0
    fi

    echo "false"
    return 1
}

detect_usage_percentage() {
    local output="$1"

    # Pattern: "You've used 77% of your weekly limit"
    local percentage=$(echo "$output" | grep -oE "You've used [0-9]+% of your weekly limit" | grep -oE "[0-9]+" | tail -1)

    if [[ -n "$percentage" ]]; then
        echo "$percentage"
        return 0
    fi

    echo "0"
    return 1
}

detect_early_warning() {
    local output="$1"

    # Early warning: entering extra usage territory
    if echo "$output" | grep -qE "Now using extra usage"; then
        echo "extra_usage"
        return 0
    fi

    echo "false"
    return 1
}

get_account_from_session() {
    local session=$1

    # Extract account from session name suffix: claude-N-acc1 or claude-N-acc2
    local acc_num=$(echo "$session" | grep -oE 'acc[12]$' | grep -oE '[12]')

    if [[ -n "$acc_num" ]]; then
        echo "$acc_num"
    else
        # No suffix = default to account 1
        echo "1"
    fi
}

get_target_account() {
    local current_account=$1

    if [[ "$current_account" == "1" ]]; then
        echo "2"
    else
        echo "1"
    fi
}

auto_migrate_account() {
    local session=$1
    local reason=${2:-"Rate limit detected"}

    # Get account from session name suffix (e.g., claude-2-acc1 → 1)
    local current_account=$(get_account_from_session "$session")
    local new_account=$(get_target_account "$current_account")

    # Check if new account is configured
    if [[ "$new_account" == "2" && ! -d "$HOME/.claude-account2" ]]; then
        log "[$session] Cannot migrate to account 2 - not configured"
        send_telegram "⚠️ <b>Rate Limit - Cannot Migrate</b>

<b>Session:</b> $session
<b>Issue:</b> Account 2 not configured

Setup account 2:
<code>CLAUDE_CONFIG_DIR=~/.claude-account2 claude login</code>"
        return 1
    fi

    log "[$session] Auto-migrating from account $current_account to account $new_account (reason: $reason)"

    # Update global active account
    echo "$new_account" > "$ACCOUNT_DIR/active-account"

    # Notify
    send_telegram "🔄 <b>Auto Account Migration</b>

<b>Session:</b> $session
<b>Reason:</b> $reason
<b>From:</b> Account $current_account
<b>To:</b> Account $new_account

Triggering respawn with handoff..."

    # Trigger respawn via auto-respawn script
    if [[ -x "$HOME/.claude/scripts/auto-respawn.sh" ]]; then
        # Pass the new account as working dir (hack - will be overridden)
        "$HOME/.claude/scripts/auto-respawn.sh" "$session" "rate_limit" &
        log "[$session] Auto-respawn triggered for account migration"
    else
        # Manual respawn with account
        local working_dir=$(tmux display-message -t "$session" -p "#{pane_current_path}" 2>/dev/null || echo "$HOME")

        # Kill old session
        tmux kill-session -t "$session" 2>/dev/null
        sleep 2

        # Start new session with new account
        if [[ "$new_account" == "2" ]]; then
            tmux new-session -d -s "$session" -c "$working_dir" -e "CLAUDE_CONFIG_DIR=$HOME/.claude-account2" "claude --dangerously-skip-permissions"
        else
            tmux new-session -d -s "$session" -c "$working_dir" "claude --dangerously-skip-permissions"
        fi

        sleep 3

        # Update session file with new account
        local session_file="$SCRIPT_DIR/sessions/$session"
        if [[ -f "$session_file" ]]; then
            local tmp=$(mktemp)
            jq ".account = $new_account" "$session_file" > "$tmp" && mv "$tmp" "$session_file"
        fi

        force_push "$session" "Session migrated to Account $new_account due to rate limit on Account $current_account.

Continue your work. Your context was preserved."

        log "[$session] Manual respawn completed on account $new_account"
    fi

    return 0
}

#
# RALPH Status Parsing
#

parse_ralph_status() {
    local output="$1"

    # Look for RALPH_STATUS block in output
    if echo "$output" | grep -q "RALPH_STATUS:"; then
        local status_block=$(echo "$output" | grep -A10 "RALPH_STATUS:" | head -10)

        local exit_signal=$(echo "$status_block" | grep -E "EXIT_SIGNAL:" | sed 's/.*EXIT_SIGNAL:[[:space:]]*//' | tr -d ' ' | head -1)
        local status=$(echo "$status_block" | grep -E "^STATUS:" | sed 's/.*STATUS:[[:space:]]*//' | tr -d ' ' | head -1)

        # Return: exit_signal|status
        echo "${exit_signal:-none}|${status:-unknown}"
        return 0
    fi

    echo "none|none"
    return 1
}

detect_progress() {
    local session=$1
    local output=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null)

    # Look for progress indicators in recent output
    # ✔ = tool completed, Created/Edited/Modified = file changes
    local indicators=$(echo "$output" | grep -cE "✔|✓|Created|Edited|Modified|Written|Deleted" || echo "0")

    # Store last indicator count for comparison
    local last_file="$CB_STATE_DIR/${session}.last_indicators"
    local last_count=$(cat "$last_file" 2>/dev/null || echo "0")
    echo "$indicators" > "$last_file"

    # Progress = more indicators than last check
    if [[ $indicators -gt $last_count ]]; then
        echo "true"
    else
        echo "false"
    fi
}

detect_completion_patterns() {
    local output="$1"

    # Count completion-like phrases (RALPH-style heuristic)
    local count=$(echo "$output" | grep -ciE "all done|task complete|finished|all tasks|nothing more|work is done|completed successfully" || echo "0")
    echo "$count"
}

#
# Task file integration (ralph-task.sh)
#

TASK_FILE_DIR="$HOME/.claude/handoffs"

check_task_file_complete() {
    local session=$1
    local task_file="$TASK_FILE_DIR/${session}-task.md"

    # No task file = not applicable
    [[ ! -f "$task_file" ]] && echo "no_task" && return

    # Count checkboxes
    local total=$(grep -cE "^\s*- \[[ x]\]" "$task_file" 2>/dev/null || echo "0")
    local done=$(grep -cE "^\s*- \[x\]" "$task_file" 2>/dev/null || echo "0")

    # Check EXIT_SIGNAL in task file
    local exit_signal=$(grep -A5 "RALPH_STATUS:" "$task_file" 2>/dev/null | grep "EXIT_SIGNAL:" | sed 's/.*EXIT_SIGNAL:[[:space:]]*//' | tr -d ' ')

    if [[ "$exit_signal" == "true" ]]; then
        echo "complete_signal"
    elif [[ $total -gt 0 && $done -eq $total ]]; then
        echo "complete_checkboxes"
    else
        echo "in_progress|$done/$total"
    fi
}

#
# State detection
#

detect_state() {
    local session=$1
    local output=$(tmux capture-pane -t "$session" -p 2>/dev/null)

    [[ -z "$output" ]] && echo "dead" && return

    local last_lines=$(echo "$output" | tail -20)

    # Check for RALPH_STATUS first (most reliable signal)
    local ralph_status=$(parse_ralph_status "$output")
    local exit_signal=$(echo "$ralph_status" | cut -d'|' -f1)
    local status=$(echo "$ralph_status" | cut -d'|' -f2)

    if [[ "$exit_signal" == "true" ]]; then
        echo "complete_confirmed"
        return
    fi

    if [[ "$status" == "COMPLETE" && "$exit_signal" == "false" ]]; then
        echo "phase_complete"
        return
    fi

    # Low context
    if echo "$last_lines" | grep -qE "Context left.*[0-9]%"; then
        local ctx=$(echo "$last_lines" | grep -oE "[0-9]+%" | head -1 | tr -d '%')
        [[ -n "$ctx" && "$ctx" -lt 15 ]] && echo "low_context" && return
    fi

    # Stuck states
    echo "$last_lines" | grep -qE "Would you like to proceed|❯.*1\.|❯.*2\.|Y/n|\[y/N\]" && echo "approval_prompt" && return
    echo "$last_lines" | grep -qE "plan mode on" && echo "plan_mode" && return
    echo "$last_lines" | grep -qE "^quote>|dquote>" && echo "quote_stuck" && return
    echo "$last_lines" | grep -qE "↵ send|Press up to edit" && echo "input_pending" && return

    # Working states
    echo "$last_lines" | grep -qE "thinking|Waiting|Reading|Writing|Finagling|Unravelling|Pondering|esc to interrupt" && echo "working" && return
    echo "$last_lines" | grep -qE "background task" && echo "working" && return

    # Idle
    echo "$last_lines" | grep -qE "bypass permissions" && echo "idle" && return

    echo "unknown"
}

fix_stuck_state() {
    local session=$1
    local state=$2

    log "[$session] Fixing: $state"

    case $state in
        "approval_prompt")
            tmux send-keys -t "$session" "1" Enter
            sleep 0.5
            tmux send-keys -t "$session" Enter
            ;;
        "plan_mode")
            tmux send-keys -t "$session" Escape
            sleep 0.3
            tmux send-keys -t "$session" Enter
            ;;
        "quote_stuck")
            tmux send-keys -t "$session" C-c C-u Enter
            ;;
        "input_pending")
            tmux send-keys -t "$session" Enter Enter
            ;;
        "low_context"|"dead")
            log "[$session] Restarting session"
            tmux kill-session -t "$session" 2>/dev/null
            sleep 1
            tmux new-session -d -s "$session" -c "$HOME" "claude --dangerously-skip-permissions"
            sleep 3
            force_push "$session" "Session restarted. Check your working directory and continue."
            send_telegram "🔄 <b>$session restarted</b>: $state"
            ;;
    esac
}

#
# Actions
#

force_push() {
    local session=$1
    local custom_msg=$2

    local recent=$(tmux capture-pane -t "$session" -p -S -30 2>/dev/null | grep -E "^⏺|✓|✗|☐|☒" | tail -5)

    local msg="${custom_msg:-Keep working!}

Recent activity:
$recent

REMINDERS:
1. Continue your current task
2. Send Telegram update when done:
   ~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') \"Update\"
3. Write TTS summary:
   ~/.claude/scripts/tts-write.sh \"Summary\"

Keep going!"

    tmux send-keys -t "$session" C-u 2>/dev/null
    sleep 0.2
    "$SCRIPT_DIR/inject-prompt.sh" "$session" "$msg" 2>/dev/null

    date +%s > "$STATE_DIR/${session}_last_push"
    log "[$session] Force pushed"
}

inject_reminder() {
    local session=$1

    local state=$(detect_state "$session")
    [[ "$state" = "working" ]] && return

    local reminder="📢 Reminder: When you complete tasks:

1. Send Telegram: ~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') \"Update\"
2. Write TTS: ~/.claude/scripts/tts-write.sh \"Summary\""

    tmux send-keys -t "$session" C-u 2>/dev/null
    sleep 0.2
    "$SCRIPT_DIR/inject-prompt.sh" "$session" "$reminder" 2>/dev/null
    log "[$session] Reminder sent"
}

#
# Commands
#

cmd_start() {
    if is_running; then
        echo "⚠️ Watchdog already running"
        cmd_status
        return
    fi

    # Save instances to watch
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$@" > "$INSTANCES_FILE"
        echo "📝 Watching: $*"
    else
        > "$INSTANCES_FILE"  # Empty = reminder-only mode
        echo "📝 Reminder-only mode (no instances to force-push)"
    fi

    # Start daemon in tmux
    tmux new-session -d -s watchdog "$SCRIPT_DIR/watchdog.sh daemon"
    sleep 2

    local pid=$(tmux list-panes -t watchdog -F "#{pane_pid}" 2>/dev/null | head -1)
    echo "$pid" > "$PID_FILE"

    echo "✅ Watchdog started"
    cmd_status
}

cmd_stop() {
    if ! is_running; then
        echo "⚠️ Watchdog not running"
        return
    fi

    tmux kill-session -t watchdog 2>/dev/null
    rm -f "$PID_FILE"
    echo "🛑 Watchdog stopped"
}

cmd_status() {
    local status_emoji="🔴"
    local status_text="Stopped"

    if is_running; then
        status_emoji="🟢"
        status_text="Running"
    fi

    local watched=$(get_watched_instances)
    [[ -z "$watched" ]] && watched="(none - reminder only)"

    echo "$status_emoji Watchdog: $status_text"
    echo "👀 Watching: $watched"

    if is_running && [[ -n "$(get_watched_instances)" ]]; then
        echo ""
        echo "Instance states:"
        for instance in $(get_watched_instances); do
            if tmux has-session -t "$instance" 2>/dev/null; then
                local state=$(detect_state "$instance")
                local cb_state=""
                if cb_is_open "$instance"; then
                    cb_state=" [CIRCUIT OPEN]"
                else
                    local no_prog=$(cb_get_no_progress "$instance")
                    local comps=$(cb_get_completions "$instance")
                    [[ "$no_prog" -gt 0 || "$comps" -gt 0 ]] && cb_state=" [np:$no_prog/3, comp:$comps/5]"
                fi

                # Task file status
                local task_info=""
                local task_status=$(check_task_file_complete "$instance")
                if [[ "$task_status" != "no_task" ]]; then
                    local progress=$(echo "$task_status" | cut -d'|' -f2)
                    task_info=" [task: $progress]"
                fi

                # Worker status
                local worker_info=""
                local worker_pid_file="$SCRIPT_DIR/worker-state/$instance/worker.pid"
                if [[ -f "$worker_pid_file" ]]; then
                    local worker_pid=$(cat "$worker_pid_file")
                    if kill -0 "$worker_pid" 2>/dev/null; then
                        local worker_state_file="$SCRIPT_DIR/worker-state/$instance/state.json"
                        if [[ -f "$worker_state_file" ]]; then
                            local loops=$(jq -r '.loop_count // 0' "$worker_state_file" 2>/dev/null)
                            worker_info=" [worker: loop $loops]"
                        else
                            worker_info=" [worker: running]"
                        fi
                    fi
                fi

                echo "  • $instance: $state$cb_state$task_info$worker_info"
            else
                echo "  • $instance: (not running)"
            fi
        done
    fi

    # Show active tasks
    local task_count=0
    for task_file in "$TASK_FILE_DIR"/*-task.md; do
        [[ -f "$task_file" ]] && task_count=$((task_count + 1))
    done
    if [[ $task_count -gt 0 ]]; then
        echo ""
        echo "📋 Active tasks: $task_count (use 'ralph-task.sh --list' for details)"
    fi
}

cmd_add() {
    local instance=$1
    [[ -z "$instance" ]] && echo "❌ Usage: watchdog.sh add <instance>" && return 1

    if grep -q "^${instance}$" "$INSTANCES_FILE" 2>/dev/null; then
        echo "⚠️ $instance already in watch list"
        return
    fi

    echo "$instance" >> "$INSTANCES_FILE"
    echo "✅ Added $instance"
    is_running && echo "📡 Will take effect on next cycle"
}

cmd_remove() {
    local instance=$1
    [[ -z "$instance" ]] && echo "❌ Usage: watchdog.sh remove <instance>" && return 1

    if [[ -f "$INSTANCES_FILE" ]]; then
        grep -v "^${instance}$" "$INSTANCES_FILE" > "${INSTANCES_FILE}.tmp"
        mv "${INSTANCES_FILE}.tmp" "$INSTANCES_FILE"
    fi

    echo "✅ Removed $instance"
    is_running && echo "📡 Will take effect on next cycle"
}

cmd_list() {
    local watched=$(get_watched_instances)
    if [[ -z "$watched" ]]; then
        echo "📋 Watch list: (empty - reminder only mode)"
    else
        echo "📋 Watch list:"
        for instance in $watched; do
            echo "  • $instance"
        done
    fi
}

cmd_reset() {
    local session=$1
    [[ -z "$session" ]] && echo "❌ Usage: watchdog.sh reset <session>" && return 1

    if ! cb_is_open "$session"; then
        echo "⚠️ $session circuit is not open"
        return 0
    fi

    cb_reset "$session"
    echo "✅ Circuit reset for $session"
    send_telegram "🟢 <b>Circuit Reset</b>

<b>Session:</b> $session
Circuit breaker reset. Session can resume normal operation."
}

cmd_daemon() {
    log "========================================="
    log "Watchdog v4.0 started"
    log "========================================="

    local instances=$(get_watched_instances)
    log "Watching: ${instances:-none (reminder only)}"

    # Initialize push times
    for session in $instances; do
        echo "0" > "$STATE_DIR/${session}_last_push"
    done

    send_telegram "🐕 <b>Watchdog v4.0 Started</b>

<b>Watching:</b> ${instances:-none (reminder only)}

<b>Actions:</b>
• Force push watched instances every 5 min
• TTS/Telegram reminder to ALL every 30 min
• Auto-fix stuck states"

    local last_report=$(date +%s)
    local last_reminder=$(date +%s)

    while true; do
        local instances=$(get_watched_instances)

        # Check watched instances
        for session in $instances; do
            if ! tmux has-session -t "$session" 2>/dev/null; then
                log "[$session] Not running - skipping"
                continue
            fi

            # Check if ralph-worker is managing this session
            local worker_pid_file="$SCRIPT_DIR/worker-state/$session/worker.pid"
            if [[ -f "$worker_pid_file" ]]; then
                local worker_pid=$(cat "$worker_pid_file")
                if kill -0 "$worker_pid" 2>/dev/null; then
                    log "[$session] Managed by ralph-worker (PID: $worker_pid) - skipping"
                    continue
                fi
            fi

            # Circuit breaker check FIRST
            if cb_is_open "$session"; then
                log "[$session] Circuit OPEN - skipping (needs /watchdog reset $session)"
                continue
            fi

            local state=$(detect_state "$session")
            local last_push=$(cat "$STATE_DIR/${session}_last_push" 2>/dev/null || echo "0")
            local time_since_push=$(($(date +%s) - last_push))

            # Detect progress for circuit breaker
            local had_progress=$(detect_progress "$session")
            local output=$(tmux capture-pane -t "$session" -p 2>/dev/null)
            local ralph_status=$(parse_ralph_status "$output")
            local exit_signal=$(echo "$ralph_status" | cut -d'|' -f1)

            # Check task file completion (ralph-task.sh integration)
            local task_status=$(check_task_file_complete "$session")

            log "[$session] State: $state | Progress: $had_progress | EXIT_SIGNAL: $exit_signal | Task: $task_status"

            # === RATE LIMIT DETECTION (priority order) ===

            # 1. Check usage percentage (proactive migration at 95%+)
            local usage_pct=$(detect_usage_percentage "$output")
            if [[ "$usage_pct" -ge 95 && "$usage_pct" -le 100 ]]; then
                log "[$session] Usage at ${usage_pct}% - triggering proactive migration"
                auto_migrate_account "$session" "Weekly usage at ${usage_pct}% (threshold: 95%)"
                continue
            fi

            # 2. Check for hard limit messages (immediate migration)
            local rate_limit_status=$(detect_rate_limit "$output")
            if [[ "$rate_limit_status" == "hard_limit" ]]; then
                log "[$session] Hard rate limit detected! Triggering immediate migration"
                auto_migrate_account "$session" "Hard rate limit hit"
                continue
            fi

            # 3. Check for early warning (send notification only)
            local early_warning=$(detect_early_warning "$output")
            if [[ "$early_warning" == "extra_usage" ]]; then
                # Only notify once per session (use state file to track)
                local warning_file="$STATE_DIR/${session}_extra_usage_warned"
                if [[ ! -f "$warning_file" ]]; then
                    log "[$session] Now using extra usage - sending warning"
                    send_telegram "⚠️ <b>Extra Usage Warning</b>

<b>Session:</b> $session
<b>Status:</b> Now using extra usage

Weekly limit reached, using extra capacity.
Migration will occur at 95% or hard limit."
                    touch "$warning_file"
                fi
            fi

            # Record for circuit breaker
            cb_record_progress "$session" "$had_progress" || continue
            cb_record_completion "$session" "$exit_signal" || continue

            # Handle task file completion (all checkboxes checked)
            if [[ "$task_status" == "complete_checkboxes" ]]; then
                log "[$session] Task complete (all checkboxes checked)"
                send_telegram "✅ <b>Task Complete</b>

<b>Session:</b> $session
All task checkboxes checked. Archiving task file."
                # Archive the task file
                local task_file="$TASK_FILE_DIR/${session}-task.md"
                mv "$task_file" "$TASK_FILE_DIR/${session}-task-$(date '+%Y%m%d-%H%M')-done.md" 2>/dev/null
                cb_reset "$session"
                continue
            fi

            # Handle confirmed completion via RALPH_STATUS
            if [[ "$state" == "complete_confirmed" || "$task_status" == "complete_signal" ]]; then
                log "[$session] Task complete (EXIT_SIGNAL: true)"
                # Archive the task file if exists
                local task_file="$TASK_FILE_DIR/${session}-task.md"
                [[ -f "$task_file" ]] && mv "$task_file" "$TASK_FILE_DIR/${session}-task-$(date '+%Y%m%d-%H%M')-done.md" 2>/dev/null
                continue
            fi

            # Fix stuck states
            case $state in
                "approval_prompt"|"plan_mode"|"quote_stuck"|"input_pending"|"low_context"|"dead")
                    fix_stuck_state "$session" "$state"
                    sleep 1
                    ;;
            esac

            # Force push every 5 min (but not if phase just completed)
            if [[ $time_since_push -ge $FORCE_PUSH_INTERVAL && "$state" != "phase_complete" ]]; then
                force_push "$session"
            fi

            sleep 2
        done

        local current_time=$(date +%s)

        # Status report every 30 min
        if [[ $((current_time - last_report)) -ge $REPORT_INTERVAL ]]; then
            local report="🐕 <b>Watchdog Status</b>\n\n"
            for session in $instances; do
                local state=$(detect_state "$session")
                report+="<b>$session:</b> $state\n"
            done
            send_telegram "$report"
            last_report=$current_time
        fi

        # Reminder to ALL instances every 30 min
        if [[ $((current_time - last_reminder)) -ge $REMINDER_INTERVAL ]]; then
            log "Sending reminders to all instances"
            for session in $(get_all_claude_instances); do
                inject_reminder "$session"
                sleep 1
            done
            last_reminder=$current_time
        fi

        sleep $CHECK_INTERVAL
    done
}

cmd_help() {
    cat << 'EOF'
🐕 Watchdog v4.0 (RALPH-enabled)

Usage: watchdog.sh <command> [args]

Commands:
  start [instances...]  Start watchdog (empty = reminder-only mode)
  stop                  Stop watchdog
  status                Show status (includes circuit breaker state)
  add <instance>        Add instance to watch list
  remove <instance>     Remove from watch list
  list                  List watched instances
  reset <session>       Reset circuit breaker for session

Circuit Breaker:
  Sessions auto-halt after 3 cycles with no progress or 5 completion
  indicators without EXIT_SIGNAL. Use 'reset' to resume.

RALPH_STATUS Protocol:
  Sessions should include RALPH_STATUS block with EXIT_SIGNAL: true/false
  to indicate genuine task completion vs stuck states.

Examples:
  watchdog.sh start claude-1 claude-3   # Watch specific instances
  watchdog.sh start                      # Reminder-only mode
  watchdog.sh add claude-2              # Add to watch list
  watchdog.sh status                    # Check status
  watchdog.sh reset claude-2            # Reset circuit breaker
EOF
}

#
# Main
#

case "${1:-help}" in
    start)   shift; cmd_start "$@" ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    add)     cmd_add "$2" ;;
    remove)  cmd_remove "$2" ;;
    list)    cmd_list ;;
    reset)   cmd_reset "$2" ;;
    daemon)  cmd_daemon ;;
    help|*)  cmd_help ;;
esac
