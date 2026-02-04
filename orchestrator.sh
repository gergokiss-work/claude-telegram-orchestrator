#!/bin/bash
# orchestrator.sh - Main daemon that polls Telegram for commands
# Enhanced with voice message support via OpenAI Whisper

# Don't use set -e - we handle errors gracefully to keep the daemon running

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Lock file to prevent duplicate instances
LOCK_FILE="$SCRIPT_DIR/.orchestrator.lock"
if [[ -f "$LOCK_FILE" ]]; then
    OLD_PID=$(cat "$LOCK_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Orchestrator already running (PID $OLD_PID). Exiting."
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

# Source configs - .env.local for secrets, config.env for settings
[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

LOG_FILE="$SCRIPT_DIR/logs/orchestrator.log"
LAST_UPDATE_ID=0
SESSIONS_DIR="$SCRIPT_DIR/sessions"

mkdir -p "$SCRIPT_DIR/logs" "$SESSIONS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Resolve session number to full name with account suffix
# Usage: resolve_session 2  ->  claude-2-acc1 (or claude-2-acc2 if that exists)
resolve_session() {
    local num="$1"
    # First check with active account
    local active_account=$(cat "$HOME/.claude/account-manager/active-account" 2>/dev/null || echo "1")
    local preferred="claude-${num}-acc${active_account}"
    if tmux has-session -t "$preferred" 2>/dev/null; then
        echo "$preferred"
        return 0
    fi
    # Check other account
    local other_account=$([[ "$active_account" == "1" ]] && echo "2" || echo "1")
    local fallback="claude-${num}-acc${other_account}"
    if tmux has-session -t "$fallback" 2>/dev/null; then
        echo "$fallback"
        return 0
    fi
    # Check legacy format (no suffix) for backward compatibility
    if tmux has-session -t "claude-${num}" 2>/dev/null; then
        echo "claude-${num}"
        return 0
    fi
    echo ""
    return 1
}

# Get coordinator session name (claude-0-accN)
get_coordinator() {
    local active_account=$(cat "$HOME/.claude/account-manager/active-account" 2>/dev/null || echo "1")
    local preferred="claude-0-acc${active_account}"
    if tmux has-session -t "$preferred" 2>/dev/null; then
        echo "$preferred"
        return 0
    fi
    # Check other account
    local other_account=$([[ "$active_account" == "1" ]] && echo "2" || echo "1")
    local fallback="claude-0-acc${other_account}"
    if tmux has-session -t "$fallback" 2>/dev/null; then
        echo "$fallback"
        return 0
    fi
    # Legacy
    if tmux has-session -t "claude-0" 2>/dev/null; then
        echo "claude-0"
        return 0
    fi
    echo ""
    return 1
}

#
# Helper functions for new Telegram commands
#

get_context_info() {
    local session_num="$1"
    local result=""

    if [[ -n "$session_num" ]]; then
        # Specific session - resolve to full name
        local session=$(resolve_session "$session_num")
        if [[ -n "$session" ]]; then
            local output=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null)
            local ctx=$(echo "$output" | grep -oE "Context left.*[0-9]+%" | tail -1 || echo "")
            local tokens=$(echo "$output" | grep -oE "↓ [0-9.]+k tokens" | tail -1 || echo "")
            if [[ -n "$ctx" ]]; then
                result="📊 <b>$session</b>
$ctx $tokens"
            else
                result="📊 <b>$session</b>
Context info not visible in recent output"
            fi
        else
            result="❌ Session $session not found"
        fi
    else
        # All sessions
        result="📊 <b>Context Status</b>
"
        for session in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^claude-" | sort -t- -k2 -n); do
            local output=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null)
            local ctx=$(echo "$output" | grep -oE "[0-9]+% context" | tail -1 || echo "n/a")
            result+="• <b>$session</b>: $ctx
"
        done
    fi
    echo "$result"
}

handle_circuit_cmd() {
    local args="$1"
    local session_num=$(echo "$args" | awk '{print $1}')
    local action=$(echo "$args" | awk '{print $2}')

    local CB_STATE_DIR="$SCRIPT_DIR/watchdog-state/circuits"

    if [[ -z "$session_num" ]]; then
        # Show all circuit states
        local result="🔌 <b>Circuit Breaker Status</b>
"
        for session in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -E "^claude-[0-9]+-acc[12]$|^claude-[0-9]+$" | sort -t- -k2 -n); do
            local is_open="🟢 CLOSED"
            [[ -f "$CB_STATE_DIR/${session}.open" ]] && is_open="🔴 OPEN"
            local no_prog=$(cat "$CB_STATE_DIR/${session}.no_progress" 2>/dev/null || echo "0")
            local comps=$(cat "$CB_STATE_DIR/${session}.completions" 2>/dev/null || echo "0")
            result+="• <b>$session</b>: $is_open (np:$no_prog, comp:$comps)
"
        done
        echo "$result"
    elif [[ "$action" == "reset" ]]; then
        # Reset circuit for specific session
        local session=$(resolve_session "$session_num")
        if [[ -z "$session" ]]; then
            echo "❌ Session claude-$session_num not found"
            return
        fi
        "$SCRIPT_DIR/watchdog.sh" reset "$session" 2>&1
        echo "✅ Circuit reset for $session"
    else
        # Show specific session
        local session=$(resolve_session "$session_num")
        if [[ -z "$session" ]]; then
            echo "❌ Session claude-$session_num not found"
            return
        fi
        local is_open="🟢 CLOSED"
        [[ -f "$CB_STATE_DIR/${session}.open" ]] && is_open="🔴 OPEN"
        local no_prog=$(cat "$CB_STATE_DIR/${session}.no_progress" 2>/dev/null || echo "0")
        local comps=$(cat "$CB_STATE_DIR/${session}.completions" 2>/dev/null || echo "0")
        local history=""
        [[ -f "$CB_STATE_DIR/${session}.history" ]] && history=$(tail -5 "$CB_STATE_DIR/${session}.history" 2>/dev/null | sed 's/^/  /')

        echo "🔌 <b>$session Circuit</b>
State: $is_open
No-progress cycles: $no_prog/3
Completion indicators: $comps/5

<b>Recent history:</b>
<pre>$history</pre>

💡 Use <code>/circuit $session_num reset</code> to reset"
    fi
}

get_logs() {
    local arg="$1"
    local lines=15

    if [[ -z "$arg" ]]; then
        # Watchdog logs
        local log_file="$SCRIPT_DIR/logs/watchdog.log"
        if [[ -f "$log_file" ]]; then
            local recent=$(tail -$lines "$log_file" 2>/dev/null)
            echo "📜 <b>Watchdog Logs</b> (last $lines lines)
<pre>$recent</pre>"
        else
            echo "❌ No watchdog logs found"
        fi
    else
        # Session-specific - check orchestrator log for session mentions
        local session=$(resolve_session "$arg")
        [[ -z "$session" ]] && session="claude-$arg"  # Use provided even if not running
        local log_file="$SCRIPT_DIR/logs/orchestrator.log"
        if [[ -f "$log_file" ]]; then
            local recent=$(grep "$session" "$log_file" | tail -$lines 2>/dev/null)
            if [[ -n "$recent" ]]; then
                echo "📜 <b>$session Logs</b> (last $lines mentions)
<pre>$recent</pre>"
            else
                echo "📜 No recent logs for $session"
            fi
        else
            echo "❌ No orchestrator logs found"
        fi
    fi
}

list_handoffs() {
    local handoff_dir="$HOME/.claude/handoffs"
    local result="📋 <b>Recent Handoffs</b>
"

    if [[ -d "$handoff_dir" ]]; then
        local files=$(ls -t "$handoff_dir"/*.md 2>/dev/null | head -10)
        if [[ -n "$files" ]]; then
            for f in $files; do
                local name=$(basename "$f")
                local date=$(stat -f "%Sm" -t "%m-%d %H:%M" "$f" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d' ' -f1,2 | cut -d':' -f1,2)
                result+="• <code>$name</code> ($date)
"
            done
            result+="
💡 Files at: <code>~/.claude/handoffs/</code>"
        else
            result+="No handoff files found"
        fi
    else
        result+="Handoffs directory not found"
    fi

    echo "$result"
}

trigger_respawn() {
    local session_num="$1"
    local session=$(resolve_session "$session_num")

    if [[ -z "$session" ]]; then
        echo "❌ Session claude-$session_num not found"
        return 1
    fi

    log "Manual respawn triggered for $session"

    # Call auto-respawn script if it exists
    if [[ -x "$HOME/.claude/scripts/auto-respawn.sh" ]]; then
        "$HOME/.claude/scripts/auto-respawn.sh" "$session" "manual" &
        echo "🔄 <b>Respawn triggered</b>
Session: $session
Mode: manual

Auto-respawn script started in background."
    else
        # Manual respawn: kill and restart
        local working_dir=$(tmux display-message -t "$session" -p "#{pane_current_path}" 2>/dev/null || echo "$HOME")
        tmux kill-session -t "$session" 2>/dev/null
        sleep 1
        tmux new-session -d -s "$session" -c "$working_dir" "claude --dangerously-skip-permissions"
        sleep 2
        echo "🔄 <b>Session Respawned</b>
Session: $session
Working dir: $working_dir

Session killed and restarted."
    fi
}

handle_ralph_cmd() {
    local args="$1"
    local action=$(echo "$args" | awk '{print $1}')
    local session_num=$(echo "$args" | awk '{print $2}')
    local extra=$(echo "$args" | cut -d' ' -f3-)

    case "$action" in
        start)
            # /ralph start N "task description"
            if [[ -z "$session_num" || -z "$extra" ]]; then
                echo "❌ Usage: <code>/ralph start N task description</code>
Example: <code>/ralph start 5 Implement user authentication</code>"
                return
            fi
            local session=$(resolve_session "$session_num")
            if [[ -z "$session" ]]; then
                echo "❌ Session claude-$session_num not found. Use <code>/new</code> first."
                return
            fi
            log "Starting RALPH task on $session: $extra"
            local result=$("$SCRIPT_DIR/ralph-task.sh" "$session" "$extra" 2>&1)
            echo "🚀 <b>RALPH Task Started</b>

<b>Session:</b> $session
<b>Task:</b> $extra

$result

Use <code>/ralph status $session_num</code> to check progress."
            ;;

        loop)
            # /ralph loop N [max-loops]
            if [[ -z "$session_num" ]]; then
                echo "❌ Usage: <code>/ralph loop N [max-loops]</code>
Example: <code>/ralph loop 5 50</code>"
                return
            fi
            local session=$(resolve_session "$session_num")
            local max_loops="${extra:-100}"
            if [[ -z "$session" ]]; then
                echo "❌ Session claude-$session_num not found."
                return
            fi
            # Check if task file exists
            if [[ ! -f "$HOME/.claude/handoffs/${session}-task.md" ]]; then
                echo "❌ No task file for $session. Use <code>/ralph start</code> first."
                return
            fi
            log "Starting RALPH worker loop on $session (max: $max_loops)"
            # Start in background
            nohup "$SCRIPT_DIR/ralph-task.sh" "$session" --loop "$max_loops" > "$SCRIPT_DIR/logs/ralph-${session}.log" 2>&1 &
            echo "🔄 <b>RALPH Worker Started</b>

<b>Session:</b> $session
<b>Max loops:</b> $max_loops

Worker running in background.
Use <code>/ralph status $session_num</code> to monitor."
            ;;

        status)
            # /ralph status [N]
            if [[ -z "$session_num" ]]; then
                # All workers
                local result=$("$SCRIPT_DIR/ralph-status.sh" 2>&1)
                echo "📊 <b>RALPH Workers</b>

$result"
            else
                local session=$(resolve_session "$session_num")
                [[ -z "$session" ]] && session="claude-$session_num"
                local result=$("$SCRIPT_DIR/ralph-status.sh" "$session" 2>&1)
                echo "📊 <b>RALPH Status: $session</b>

$result"
            fi
            ;;

        stop)
            # /ralph stop N
            if [[ -z "$session_num" ]]; then
                echo "❌ Usage: <code>/ralph stop N</code>"
                return
            fi
            local session=$(resolve_session "$session_num")
            [[ -z "$session" ]] && session="claude-$session_num"
            log "Stopping RALPH worker on $session"
            local result=$("$SCRIPT_DIR/ralph-task.sh" "$session" --stop-worker 2>&1)
            echo "🛑 <b>RALPH Worker Stopped</b>

<b>Session:</b> $session
$result"
            ;;

        cancel)
            # /ralph cancel N - Cancel task entirely
            if [[ -z "$session_num" ]]; then
                echo "❌ Usage: <code>/ralph cancel N</code>"
                return
            fi
            local session=$(resolve_session "$session_num")
            [[ -z "$session" ]] && session="claude-$session_num"
            log "Canceling RALPH task on $session"
            local result=$("$SCRIPT_DIR/ralph-task.sh" "$session" --cancel 2>&1)
            echo "❌ <b>RALPH Task Canceled</b>

<b>Session:</b> $session
$result"
            ;;

        reset)
            # /ralph reset N - Reset circuit breaker (alias to /circuit N reset)
            if [[ -z "$session_num" ]]; then
                echo "❌ Usage: <code>/ralph reset N</code>"
                return
            fi
            local result=$(handle_circuit_cmd "$session_num reset")
            echo "$result"
            ;;

        list|tasks)
            # /ralph list - Show active tasks
            local result="📋 <b>Active RALPH Tasks</b>
"
            for task_file in "$HOME/.claude/handoffs"/*-task.md; do
                [[ -f "$task_file" ]] || continue
                local name=$(basename "$task_file" | sed 's/-task\.md//')
                local status=$(grep -m1 "^\*\*Status:\*\*" "$task_file" 2>/dev/null | sed 's/.*\*\*Status:\*\* //')
                local created=$(grep -m1 "^\*\*Created:\*\*" "$task_file" 2>/dev/null | sed 's/.*\*\*Created:\*\* //')
                result+="• <b>$name</b>: $status ($created)
"
            done
            if [[ "$result" == *"Active RALPH Tasks"*$'\n' ]]; then
                result+="No active tasks."
            fi
            echo "$result"
            ;;

        *)
            echo "🤖 <b>RALPH Commands</b>

<b>Task Management:</b>
• <code>/ralph start N task</code> - Start task on session N
• <code>/ralph loop N [max]</code> - Start worker loop (default: 100)
• <code>/ralph stop N</code> - Stop worker loop
• <code>/ralph cancel N</code> - Cancel task entirely
• <code>/ralph list</code> - Show active tasks

<b>Monitoring:</b>
• <code>/ralph status [N]</code> - Show worker status
• <code>/ralph reset N</code> - Reset circuit breaker

<b>Example:</b>
<code>/ralph start 5 Implement user auth</code>
<code>/ralph loop 5 50</code>
<code>/ralph status 5</code>"
            ;;
    esac
}

show_help() {
    echo "🤖 <b>Telegram Orchestrator Commands</b>

<b>Session Management:</b>
• <code>/status</code> - Show all session states
• <code>/new [prompt]</code> - Start new session
• <code>/kill N</code> - Kill session N
• <code>/resume query</code> - Resume matching session
• <code>/respawn N</code> - Respawn session N
• <code>/sessions</code> - Show session metadata

<b>Account Management:</b>
• <code>/account</code> - Show active account
• <code>/account 1|2</code> - Switch account
• <code>/account rotate</code> - Toggle accounts
• <code>/migrate N [1|2]</code> - Migrate session to other account

<b>Monitoring:</b>
• <code>/context [N]</code> - Show context %
• <code>/circuit [N] [reset]</code> - Circuit breaker
• <code>/logs [N]</code> - View logs
• <code>/handoffs</code> - List handoff files
• <code>/watchdog [cmd]</code> - Watchdog control

<b>RALPH Tasks:</b>
• <code>/ralph start N task</code> - Start task
• <code>/ralph status [N]</code> - Worker status
• <code>/ralph stop N</code> - Stop worker

<b>Communication:</b>
• <code>/inject N msg</code> - Inject to session
• <code>/tts [on|off]</code> - Toggle TTS
• Reply to message → routes to that session

<b>Tips:</b>
• Reply to a [claude-N] message to send to that session
• Just send text to route to coordinator (claude-0)"
}

list_sessions() {
    local result="📋 <b>Session Metadata</b>
"
    local sessions_dir="$SCRIPT_DIR/sessions"

    for session in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -E "^claude-[0-9]+-acc[12]$|^claude-[0-9]+$" | sort -t- -k2 -n); do
        local meta_file="$sessions_dir/$session"
        result+="
<b>$session</b>"

        if [[ -f "$meta_file" ]]; then
            local started=$(jq -r '.started // "unknown"' "$meta_file" 2>/dev/null)
            local cwd=$(jq -r '.cwd // "~"' "$meta_file" 2>/dev/null)
            local task=$(jq -r '.task // ""' "$meta_file" 2>/dev/null)
            local role=$(jq -r '.role // ""' "$meta_file" 2>/dev/null)

            # Format started time
            if [[ "$started" != "unknown" ]]; then
                started=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started%%+*}" "+%H:%M" 2>/dev/null || echo "$started")
            fi

            result+=" (started $started)"
            [[ -n "$role" ]] && result+=" [${role}]"
            result+="
  📂 <code>${cwd/#$HOME/~}</code>"
            [[ -n "$task" && "$task" != "null" ]] && result+="
  📝 ${task:0:60}..."
        else
            result+=" (no metadata)"
        fi
        result+="
"
    done

    echo "$result"
}

rotate_logs() {
    local log_dir="$SCRIPT_DIR/logs"
    local max_size=$((5 * 1024 * 1024))  # 5MB
    local max_files=5

    for log_file in "$log_dir"/*.log; do
        [[ -f "$log_file" ]] || continue

        local size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)

        if [[ $size -gt $max_size ]]; then
            # Rotate: .log -> .log.1 -> .log.2 etc
            for i in $(seq $((max_files - 1)) -1 1); do
                [[ -f "${log_file}.$i" ]] && mv "${log_file}.$i" "${log_file}.$((i + 1))"
            done
            mv "$log_file" "${log_file}.1"
            touch "$log_file"
            log "Rotated $log_file (was ${size} bytes)"
        fi
    done
}

get_status() {
    local status_msg=""
    local active_count=0
    local thinking_count=0
    local idle_count=0
    local done_count=0
    local acc1_count=0
    local acc2_count=0

    # Check tmux sessions - get directly from tmux
    for session_name in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -E "^claude-" | sort -t- -k2 -n); do
        if tmux has-session -t "$session_name" 2>/dev/null; then
            active_count=$((active_count + 1))

            # Get output - capture more for better detection
            local full_output=$(tmux capture-pane -t "$session_name" -p 2>/dev/null)
            local last_lines=$(echo "$full_output" | tail -15)

            # Extract context percentage
            local context_pct=$(echo "$full_output" | grep -oE "[0-9]+% \([0-9]+k\)" | tail -1)
            local pct_num=$(echo "$context_pct" | grep -oE "^[0-9]+" || echo "0")

            # Determine account from env var FIRST, then fall back to session name
            local account=""
            local cfg=$(tmux show-environment -t "$session_name" CLAUDE_CONFIG_DIR 2>/dev/null | cut -d= -f2)
            local is_acc2=false

            # Check actual env var first (most reliable)
            if [[ "$cfg" == *"account2"* ]]; then
                is_acc2=true
            # Fall back to session name pattern only if env confirms it
            elif [[ "$session_name" == *"-acc2"* ]] && [[ -n "$cfg" ]] && [[ "$cfg" != "-CLAUDE_CONFIG_DIR" ]]; then
                is_acc2=true
            fi
            # Note: if name says -acc2 but env not set, it's actually acc1 (bug in spawn)

            # Set account label and count
            if $is_acc2; then
                account="②"
                acc2_count=$((acc2_count + 1))
            elif echo "$full_output" | grep -q "extra usage"; then
                account="①⚠"
                acc1_count=$((acc1_count + 1))
            else
                account="①"
                acc1_count=$((acc1_count + 1))
            fi

            # Detect state
            local state_icon=""
            local state_label=""
            local task_status=""

            # Check for TASKS_REMAINING
            local tasks_remaining=$(echo "$full_output" | grep -oE "TASKS_REMAINING: [0-9]+" | tail -1 | grep -oE "[0-9]+")
            if [[ "$tasks_remaining" == "0" ]]; then
                task_status="✅"
                done_count=$((done_count + 1))
            elif [[ -n "$tasks_remaining" ]]; then
                task_status="📋$tasks_remaining"
            fi

            # Patterns for detection
            local think_pattern="[✳✶✻✢·⏺] [A-Z][a-z]+…"
            local done_pattern="✻ (Cogitated|Worked|Baked|Crunched|Churned|Sautéed|Brewed|Cooked|Forming) for"

            # Detect state - priority order
            if echo "$last_lines" | grep -qE "$think_pattern"; then
                state_icon="⏳"
                state_label="working"
                thinking_count=$((thinking_count + 1))
            elif echo "$last_lines" | grep -qE "$done_pattern"; then
                state_icon="🟢"
                state_label="idle"
                idle_count=$((idle_count + 1))
            elif echo "$last_lines" | grep -q "^❯"; then
                state_icon="🟢"
                state_label="idle"
                idle_count=$((idle_count + 1))
            else
                state_icon="💬"
                state_label="ready"
                idle_count=$((idle_count + 1))
            fi

            # Context warning indicator
            local ctx_warn=""
            if [[ $pct_num -ge 60 ]]; then
                ctx_warn="🔴"
            elif [[ $pct_num -ge 50 ]]; then
                ctx_warn="🟡"
            fi

            # Special handling for coordinator
            if [[ "$session_name" =~ ^claude-0(-acc[12])?$ ]]; then
                state_icon="🎯"
            fi

            # Build status line
            status_msg+="$state_icon <code>$session_name</code> $account"
            [[ -n "$context_pct" ]] && status_msg+=" <b>$context_pct</b>$ctx_warn"
            [[ -n "$task_status" ]] && status_msg+=" $task_status"
            status_msg+="
"
        fi
    done

    # Check cursor sessions (claude-cursor-N)
    for session_file in "$SESSIONS_DIR"/claude-cursor-*; do
        [[ -f "$session_file" ]] || continue
        [[ "$session_file" == *.queue ]] && continue

        session_name=$(basename "$session_file")
        active_count=$((active_count + 1))

        local queue_file="$SESSIONS_DIR/${session_name}.queue"
        local pending=""
        if [[ -f "$queue_file" ]]; then
            pending=" 📬"
        fi

        status_msg+="💻 <code>$session_name</code> (cursor)$pending
"
    done

    if [[ -z "$status_msg" ]]; then
        status_msg="No active sessions. Use /new to start one."
    else
        local summary="🐝 <b>SWARM: $active_count sessions</b>
"
        summary+="├ ⏳ $thinking_count working · 🟢 $idle_count idle
"
        summary+="├ ✅ $done_count done · 📋 tasks pending
"
        summary+="└ ① Acc1: $acc1_count · ② Acc2: $acc2_count
"
        status_msg="$summary
$status_msg"
    fi

    echo "$status_msg"
}

inject_input() {
    local session="$1"
    local input="$2"
    local from_telegram="${3:-false}"

    # Handle claude-cursor-N sessions (non-tmux, running in Cursor/terminal)
    if [[ "$session" == claude-cursor-* ]]; then
        local session_file="$SESSIONS_DIR/$session"
        if [[ ! -f "$session_file" ]]; then
            log "Cursor session $session not found"
            "$SCRIPT_DIR/notify.sh" "error" "$session" "Session not found or closed"
            return 1
        fi

        # Append summary instruction
        if [[ "$from_telegram" == "true" ]]; then
            input="$input
<tg>send-summary.sh</tg>"
        fi

        # Write to queue file for the cursor session
        local queue_file="$SESSIONS_DIR/${session}.queue"
        echo "---[$(date '+%H:%M:%S')]---" >> "$queue_file"
        echo "$input" >> "$queue_file"

        # Skip macOS notification - user doesn't want popups

        log "Queued for $session: ${input:0:100}..."
        "$SCRIPT_DIR/notify.sh" "update" "$session" "Message queued. Check queue with:
cat ~/.claude/telegram-orchestrator/sessions/${session}.queue"
        return 0
    fi

    # Handle tmux sessions (claude-N)
    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "Session $session not found"
        "$SCRIPT_DIR/notify.sh" "error" "$session" "Session not found"
        return 1
    fi

    # Append summary instruction for Telegram messages (subtle, at end)
    if [[ "$from_telegram" == "true" ]]; then
        input="$input
<tg>send-summary.sh</tg>"
    fi

    # Use temp file + load-buffer for reliable long message injection
    local tmpfile=$(mktemp)
    printf '%s' "$input" > "$tmpfile"
    tmux load-buffer -b telegram_msg "$tmpfile"
    tmux paste-buffer -b telegram_msg -t "$session"
    tmux delete-buffer -b telegram_msg 2>/dev/null || true
    rm -f "$tmpfile"

    # Press Enter (use hex code 0d for reliability)
    sleep 0.5
    tmux send-keys -t "$session" -H 0d

    log "Injected to $session: ${input:0:100}..."
}

kill_session() {
    local session="$1"

    if tmux has-session -t "$session" 2>/dev/null; then
        tmux send-keys -t "$session" "/exit"
        tmux send-keys -t "$session" -H 0d
        sleep 2
        tmux kill-session -t "$session" 2>/dev/null || true
        log "Killed session $session"
        "$SCRIPT_DIR/notify.sh" "complete" "$session" "Session killed by user"
    fi

    rm -f "$SESSIONS_DIR/$session" "$SESSIONS_DIR/$session.monitor.pid"
}

# Process voice message - transcribe and return text
process_voice() {
    local file_id="$1"
    local message_id="$2"
    local chat_id="$3"
    local target_session="$4"  # Optional: from reply routing

    log "Processing voice message: $file_id (target: ${target_session:-auto})"

    # Call transcription script
    transcription=$("$SCRIPT_DIR/src/voice/transcribe.sh" "$file_id" "$message_id" 2>&1)

    if [[ "$transcription" == ERROR* ]]; then
        log "Voice transcription failed: $transcription"
        "$SCRIPT_DIR/notify.sh" "error" "system" "Voice transcription failed: $transcription"
        return 1
    fi

    log "Transcribed: $transcription"

    # Process the transcribed text as a regular message, with reply routing if provided
    process_message "$transcription" "$chat_id" "$target_session"
}

# Process photo message - download and inject path to Claude
process_photo() {
    local file_id="$1"
    local message_id="$2"
    local chat_id="$3"
    local target_session="$4"  # Optional: from reply routing
    local caption="$5"         # Optional: photo caption

    log "Processing photo: $file_id (target: ${target_session:-auto})"

    # Download the image
    local image_path=$("$SCRIPT_DIR/src/image/download.sh" "$file_id" "$message_id" 2>&1)

    if [[ "$image_path" == ERROR* ]]; then
        log "Photo download failed: $image_path"
        "$SCRIPT_DIR/notify.sh" "error" "system" "Photo download failed: $image_path"
        return 1
    fi

    log "Downloaded image: $image_path"

    # Build message for Claude
    local message="[Image attached: $image_path]

Please view this image using the Read tool and analyze it."

    if [[ -n "$caption" ]]; then
        message="$caption

[Image attached: $image_path]"
    fi

    # Use target_session if provided, otherwise use coordinator
    local session_to_use="$target_session"
    if [[ -z "$session_to_use" ]]; then
        session_to_use=$(get_coordinator)

        # Ensure coordinator is running
        if [[ -z "$session_to_use" ]]; then
            log "Coordinator not running, starting..."
            "$SCRIPT_DIR/start-claude.sh" --coordinator
            sleep 3
            session_to_use=$(get_coordinator)
        fi
    fi

    inject_input "$session_to_use" "$message" "true"
    "$SCRIPT_DIR/notify.sh" "update" "$session_to_use" "📷 Image received and sent to $session_to_use"
}

process_message() {
    local message="$1"
    local chat_id="$2"
    local target_session="$3"  # Optional: specific session from reply routing

    if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        sed -i '' "s/TELEGRAM_CHAT_ID=\"\"/TELEGRAM_CHAT_ID=\"$chat_id\"/" "$SCRIPT_DIR/config.env"
        source "$SCRIPT_DIR/config.env"
        log "Auto-configured chat ID: $chat_id"
    fi

    if [[ "$message" == /help* ]]; then
        result=$(show_help)
        "$SCRIPT_DIR/notify.sh" "update" "help" "$result"

    elif [[ "$message" == /sessions* ]]; then
        result=$(list_sessions)
        "$SCRIPT_DIR/notify.sh" "update" "sessions" "$result"

    elif [[ "$message" == /status* ]]; then
        status_result=$(get_status)
        "$SCRIPT_DIR/notify.sh" "update" "status" "$status_result"

    elif [[ "$message" == /new* ]]; then
        initial_prompt="${message#/new}"
        initial_prompt="${initial_prompt# }"
        "$SCRIPT_DIR/start-claude.sh" "$initial_prompt"

    elif [[ "$message" == /tts* ]]; then
        tts_arg="${message#/tts}"
        tts_arg="${tts_arg# }"
        if [[ -z "$tts_arg" ]]; then
            # No args = toggle
            result=$("$HOME/.claude/scripts/tts-toggle.sh" toggle 2>&1)
        else
            # Pass args (on/off/status)
            result=$("$HOME/.claude/scripts/tts-toggle.sh" "$tts_arg" 2>&1)
        fi
        "$SCRIPT_DIR/notify.sh" "update" "system" "$result"

    elif [[ "$message" == /kill* ]]; then
        session_num="${message#/kill}"
        session_num="${session_num# }"
        if [[ -n "$session_num" ]]; then
            local session=$(resolve_session "$session_num")
            if [[ -n "$session" ]]; then
                kill_session "$session"
            else
                "$SCRIPT_DIR/notify.sh" "error" "system" "Session claude-$session_num not found"
            fi
        else
            "$SCRIPT_DIR/notify.sh" "error" "system" "Usage: /kill <number>"
        fi

    elif [[ "$message" == /resume* ]]; then
        query="${message#/resume}"
        query="${query# }"
        if [[ -z "$query" ]]; then
            "$SCRIPT_DIR/notify.sh" "error" "system" "Usage: /resume <description>
Example: /resume the auth bug fix"
        else
            "$SCRIPT_DIR/notify.sh" "update" "system" "Searching for session: $query..."
            session_id=$("$SCRIPT_DIR/find-session.sh" "$query" 2>/dev/null)
            if [[ -n "$session_id" ]]; then
                log "Found session to resume: $session_id"
                "$SCRIPT_DIR/start-claude.sh" --resume "$session_id" --query "$query"
            else
                "$SCRIPT_DIR/notify.sh" "error" "system" "No matching session found for: $query"
            fi
        fi

    elif [[ "$message" == /watchdog* ]]; then
        watchdog_args="${message#/watchdog}"
        watchdog_args="${watchdog_args# }"
        if [[ -z "$watchdog_args" ]]; then
            # No args = status
            result=$("$SCRIPT_DIR/watchdog.sh" status 2>&1)
            "$SCRIPT_DIR/notify.sh" "update" "watchdog" "$result"
        else
            # Pass args to control script
            result=$("$SCRIPT_DIR/watchdog.sh" $watchdog_args 2>&1)
            "$SCRIPT_DIR/notify.sh" "update" "watchdog" "$result"
        fi

    elif [[ "$message" == /context* ]]; then
        # /context [N] - Show context % for session N (default: all)
        session_num="${message#/context}"
        session_num="${session_num# }"
        result=$(get_context_info "$session_num")
        "$SCRIPT_DIR/notify.sh" "update" "context" "$result"

    elif [[ "$message" == /circuit* ]]; then
        # /circuit [N] [reset] - Show/reset circuit breaker
        circuit_args="${message#/circuit}"
        circuit_args="${circuit_args# }"
        result=$(handle_circuit_cmd "$circuit_args")
        "$SCRIPT_DIR/notify.sh" "update" "circuit" "$result"

    elif [[ "$message" == /inject* ]]; then
        # /inject N <message> - Direct inject to session N
        inject_args="${message#/inject}"
        inject_args="${inject_args# }"
        session_num=$(echo "$inject_args" | awk '{print $1}')
        inject_msg=$(echo "$inject_args" | cut -d' ' -f2-)
        if [[ -z "$session_num" || -z "$inject_msg" || "$inject_msg" == "$session_num" ]]; then
            "$SCRIPT_DIR/notify.sh" "error" "system" "Usage: /inject <N> <message>"
        else
            local session=$(resolve_session "$session_num")
            if [[ -n "$session" ]]; then
                inject_input "$session" "$inject_msg" "true"
                "$SCRIPT_DIR/notify.sh" "update" "inject" "💉 Injected to $session"
            else
                "$SCRIPT_DIR/notify.sh" "error" "system" "Session claude-$session_num not found"
            fi
        fi

    elif [[ "$message" == /logs* ]]; then
        # /logs [N] - Get recent logs from session N or watchdog
        logs_arg="${message#/logs}"
        logs_arg="${logs_arg# }"
        result=$(get_logs "$logs_arg")
        "$SCRIPT_DIR/notify.sh" "update" "logs" "$result"

    elif [[ "$message" == /handoffs* ]]; then
        # /handoffs - List recent handoff files
        result=$(list_handoffs)
        "$SCRIPT_DIR/notify.sh" "update" "handoffs" "$result"

    elif [[ "$message" == /respawn* ]]; then
        # /respawn N - Manual respawn trigger for session N
        session_num="${message#/respawn}"
        session_num="${session_num# }"
        if [[ -z "$session_num" ]]; then
            "$SCRIPT_DIR/notify.sh" "error" "system" "Usage: /respawn <N>"
        else
            result=$(trigger_respawn "$session_num")
            "$SCRIPT_DIR/notify.sh" "update" "respawn" "$result"
        fi

    elif [[ "$message" == /ralph* ]]; then
        # /ralph <cmd> - RALPH task management
        ralph_args="${message#/ralph}"
        ralph_args="${ralph_args# }"
        result=$(handle_ralph_cmd "$ralph_args")
        "$SCRIPT_DIR/notify.sh" "update" "ralph" "$result"

    elif [[ "$message" == /account* ]]; then
        # /account [1|2|rotate] - Manage Claude accounts
        account_arg="${message#/account}"
        account_arg="${account_arg# }"
        ACCOUNT_SCRIPT="$HOME/.claude/account-manager/rotate.sh"

        if [[ ! -x "$ACCOUNT_SCRIPT" ]]; then
            "$SCRIPT_DIR/notify.sh" "error" "account" "Account manager not installed.
Run setup first."
        elif [[ -z "$account_arg" ]]; then
            result=$("$ACCOUNT_SCRIPT" status 2>&1)
            "$SCRIPT_DIR/notify.sh" "update" "account" "$result"
        elif [[ "$account_arg" == "1" || "$account_arg" == "2" ]]; then
            result=$("$ACCOUNT_SCRIPT" "$account_arg" 2>&1)
            "$SCRIPT_DIR/notify.sh" "update" "account" "$result
New sessions will use Account $account_arg"
        elif [[ "$account_arg" == "rotate" || "$account_arg" == "switch" ]]; then
            result=$("$ACCOUNT_SCRIPT" rotate 2>&1)
            new_account=$(cat "$HOME/.claude/account-manager/active-account")
            "$SCRIPT_DIR/notify.sh" "update" "account" "$result
New sessions will use Account $new_account"
        else
            "$SCRIPT_DIR/notify.sh" "error" "account" "Usage: /account [1|2|rotate]
• /account - Show current
• /account 1 - Use account 1
• /account 2 - Use account 2
• /account rotate - Toggle"
        fi

    elif [[ "$message" == /migrate* ]]; then
        # /migrate N [account] - Migrate session N to other account (or specific account)
        migrate_args="${message#/migrate}"
        migrate_args="${migrate_args# }"
        session_num=$(echo "$migrate_args" | awk '{print $1}')
        target_account=$(echo "$migrate_args" | awk '{print $2}')

        if [[ -z "$session_num" ]]; then
            "$SCRIPT_DIR/notify.sh" "error" "migrate" "Usage: /migrate N [1|2]
• /migrate 5 - Migrate to other account
• /migrate 5 2 - Migrate to account 2"
        else
            session="claude-$session_num"
            if ! tmux has-session -t "$session" 2>/dev/null; then
                "$SCRIPT_DIR/notify.sh" "error" "migrate" "Session $session not found"
            else
                # Get current account
                session_file="$SCRIPT_DIR/sessions/$session"
                current_account=$(jq -r '.account // 1' "$session_file" 2>/dev/null || echo "1")

                # Determine target
                if [[ -z "$target_account" ]]; then
                    # Toggle
                    if [[ "$current_account" == "1" ]]; then
                        target_account="2"
                    else
                        target_account="1"
                    fi
                fi

                if [[ "$target_account" == "$current_account" ]]; then
                    "$SCRIPT_DIR/notify.sh" "update" "migrate" "⚠️ $session is already on Account $current_account"
                else
                    # Check if target account is configured
                    if [[ "$target_account" == "2" && ! -d "$HOME/.claude-account2" ]]; then
                        "$SCRIPT_DIR/notify.sh" "error" "migrate" "Account 2 not configured.
Setup: <code>CLAUDE_CONFIG_DIR=~/.claude-account2 claude login</code>"
                    else
                        "$SCRIPT_DIR/notify.sh" "update" "migrate" "🔄 <b>Migrating $session</b>

From: Account $current_account
To: Account $target_account

Creating handoff and respawning..."

                        # Update global active account
                        echo "$target_account" > "$HOME/.claude/account-manager/active-account"

                        # Get working directory
                        working_dir=$(tmux display-message -t "$session" -p "#{pane_current_path}" 2>/dev/null || echo "$HOME")

                        # Kill old session
                        tmux kill-session -t "$session" 2>/dev/null
                        sleep 2

                        # Start new session with target account
                        if [[ "$target_account" == "2" ]]; then
                            tmux new-session -d -s "$session" -c "$working_dir" -e "CLAUDE_CONFIG_DIR=$HOME/.claude-account2" "claude --dangerously-skip-permissions"
                        else
                            tmux new-session -d -s "$session" -c "$working_dir" "claude --dangerously-skip-permissions"
                        fi

                        sleep 3

                        # Update session file
                        if [[ -f "$session_file" ]]; then
                            tmp=$(mktemp)
                            jq ".account = $target_account" "$session_file" > "$tmp" && mv "$tmp" "$session_file"
                        fi

                        # Inject continuation message
                        "$SCRIPT_DIR/inject-prompt.sh" "$session" "🔄 Session migrated to Account $target_account (was Account $current_account).

Your working directory: $working_dir

Continue your work. If you had context from previous session, check recent handoffs:
ls -la ~/.claude/handoffs/ | tail -5" 2>/dev/null

                        "$SCRIPT_DIR/notify.sh" "update" "migrate" "✅ <b>Migration Complete</b>

$session now on Account $target_account
Working dir: $working_dir"
                    fi
                fi
            fi
        fi

    else
        # Use target_session if provided (from reply routing), otherwise use coordinator
        local session_to_use="$target_session"
        if [[ -z "$session_to_use" ]]; then
            # Default to coordinator
            session_to_use=$(get_coordinator)

            # Ensure coordinator is running
            if [[ -z "$session_to_use" ]]; then
                log "Coordinator not running, starting..."
                "$SCRIPT_DIR/start-claude.sh" --coordinator
                sleep 3
                session_to_use=$(get_coordinator)
            fi
        fi

        if [[ "$session_to_use" == claude-cursor-* ]]; then
            # Cursor session - inject_input handles the queue
            inject_input "$session_to_use" "$message" "true"
        elif tmux has-session -t "$session_to_use" 2>/dev/null; then
            # Tmux session
            inject_input "$session_to_use" "$message" "true"
        else
            "$SCRIPT_DIR/notify.sh" "error" "system" "Session $session_to_use not found."
        fi
    fi
}

# Ensure coordinator (claude-0-accN) is running
ensure_coordinator() {
    local coord=$(get_coordinator)
    if [[ -z "$coord" ]]; then
        log "Starting coordinator..."
        "$SCRIPT_DIR/start-claude.sh" --coordinator
        sleep 3  # Give it time to start
    fi
}

# Main loop
log "Orchestrator starting..."
log "Polling Telegram every ${POLL_INTERVAL}s"

# Start coordinator on boot
ensure_coordinator

# Start Clawdbot lobby session if not running
if ! tmux has-session -t "lobby" 2>/dev/null; then
    log "Starting Clawdbot lobby session..."
    "$SCRIPT_DIR/start-lobby.sh" 2>/dev/null || true
fi

# Log rotation tracking
LAST_LOG_ROTATION=$(date +%s)
LOG_ROTATION_INTERVAL=3600  # Every hour

while true; do
    # Periodic log rotation
    current_time=$(date +%s)
    if [[ $((current_time - LAST_LOG_ROTATION)) -ge $LOG_ROTATION_INTERVAL ]]; then
        rotate_logs
        LAST_LOG_ROTATION=$current_time
    fi
    response=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$((LAST_UPDATE_ID + 1))&timeout=30" 2>/dev/null || echo '{"ok":false}')

    if [[ $(echo "$response" | jq -r '.ok') == "true" ]]; then
        updates=$(echo "$response" | jq -c '.result[]' 2>/dev/null || echo "")

        while IFS= read -r update; do
            [[ -z "$update" ]] && continue

            update_id=$(echo "$update" | jq -r '.update_id')
            chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
            message_id=$(echo "$update" | jq -r '.message.message_id // empty')

            # Extract reply context FIRST (applies to both voice and text)
            reply_to_text=$(echo "$update" | jq -r '.message.reply_to_message.text // empty')
            target_session=""
            if [[ -n "$reply_to_text" ]]; then
                # Match [claude-N-accM] or [claude-N] for tmux sessions
                if [[ "$reply_to_text" =~ \[claude-([0-9]+)-acc([12])\] ]]; then
                    target_session="claude-${BASH_REMATCH[1]}-acc${BASH_REMATCH[2]}"
                    log "Reply routing detected: $target_session"
                elif [[ "$reply_to_text" =~ \[claude-([0-9]+)\] ]]; then
                    # Legacy format - resolve to actual session
                    local resolved=$(resolve_session "${BASH_REMATCH[1]}")
                    if [[ -n "$resolved" ]]; then
                        target_session="$resolved"
                    else
                        target_session="claude-${BASH_REMATCH[1]}"
                    fi
                    log "Reply routing detected: $target_session"
                # Match [claude-cursor-N] for cursor sessions
                elif [[ "$reply_to_text" =~ \[claude-cursor-([0-9]+)\] ]]; then
                    target_session="claude-cursor-${BASH_REMATCH[1]}"
                    log "Reply routing detected: $target_session"
                fi
            fi

            # Check for voice message
            voice_file_id=$(echo "$update" | jq -r '.message.voice.file_id // empty')

            if [[ -n "$voice_file_id" && -n "$chat_id" ]]; then
                log "Received voice message from $chat_id (target: ${target_session:-auto})"
                process_voice "$voice_file_id" "$message_id" "$chat_id" "$target_session"
                LAST_UPDATE_ID=$update_id
                continue
            fi

            # Check for photo message (get largest size - last in array)
            photo_file_id=$(echo "$update" | jq -r '.message.photo[-1].file_id // empty')
            photo_caption=$(echo "$update" | jq -r '.message.caption // empty')

            if [[ -n "$photo_file_id" && -n "$chat_id" ]]; then
                log "Received photo from $chat_id (target: ${target_session:-auto})"
                process_photo "$photo_file_id" "$message_id" "$chat_id" "$target_session" "$photo_caption"
                LAST_UPDATE_ID=$update_id
                continue
            fi

            # Check for text message
            message_text=$(echo "$update" | jq -r '.message.text // empty')

            if [[ -n "$message_text" && -n "$chat_id" ]]; then
                if [[ -n "$target_session" ]]; then
                    log "Reply to $target_session: $message_text"
                    inject_input "$target_session" "$message_text" "true"
                else
                    log "Received: $message_text from $chat_id"
                    process_message "$message_text" "$chat_id"
                fi
            fi

            LAST_UPDATE_ID=$update_id
        done <<< "$updates"
    else
        log "Telegram API error, retrying..."
    fi

    sleep "$POLL_INTERVAL"
done
