#!/bin/bash
# refinement-loop.sh - Autonomous refinement daemon for orchestrator v2
#
# Monitors agent summaries and injects escalating refinement prompts
# when the user doesn't reply within the configured timeout.
#
# Usage:
#   refinement-loop.sh start    - Start daemon in tmux
#   refinement-loop.sh stop     - Stop daemon
#   refinement-loop.sh status   - Show status
#   refinement-loop.sh daemon   - Run daemon loop (internal)
#   refinement-loop.sh trigger <session>  - Manually trigger refinement
#   refinement-loop.sh cancel <session>   - Cancel timer for session
#   refinement-loop.sh config   - Show current config

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.claude/refinement-loop"
CONFIG_FILE="$STATE_DIR/refinement-config.json"
LOG_FILE="$SCRIPT_DIR/logs/refinement-loop.log"
PID_FILE="$STATE_DIR/refinement-loop.pid"
INJECT_SCRIPT="$SCRIPT_DIR/inject-prompt.sh"

mkdir -p "$STATE_DIR"/{events,replies,timers,snapshots,context} "$SCRIPT_DIR/logs"

#
# Logging
#

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [refinement] $*" | tee -a "$LOG_FILE"
}

#
# Configuration
#

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        ENABLED=$(jq -r '.enabled // true' "$CONFIG_FILE")
        TIMER_SECONDS=$(jq -r '.timer_seconds // 300' "$CONFIG_FILE")
        MAX_ROUNDS=$(jq -r '.max_rounds // 3' "$CONFIG_FILE")
        SCAN_INTERVAL=$(jq -r '.daemon_scan_interval // 10' "$CONFIG_FILE")
        SNAPSHOT_LINES=$(jq -r '.snapshot_lines // 100' "$CONFIG_FILE")
        AUTO_SELF_DIRECT_ROUND=$(jq -r '.auto_self_direct_round // 3' "$CONFIG_FILE")

        # Load escalation intervals as array
        INTERVAL_1=$(jq -r '.escalation_intervals[0] // 300' "$CONFIG_FILE")
        INTERVAL_2=$(jq -r '.escalation_intervals[1] // 300' "$CONFIG_FILE")
        INTERVAL_3=$(jq -r '.escalation_intervals[2] // 300' "$CONFIG_FILE")

        # Load excluded sessions
        EXCLUDED_SESSIONS=$(jq -r '.excluded_sessions // [] | .[]' "$CONFIG_FILE" 2>/dev/null)
    else
        ENABLED=true
        TIMER_SECONDS=300
        MAX_ROUNDS=3
        SCAN_INTERVAL=10
        SNAPSHOT_LINES=100
        AUTO_SELF_DIRECT_ROUND=3
        INTERVAL_1=300
        INTERVAL_2=300
        INTERVAL_3=300
        EXCLUDED_SESSIONS=""
    fi
}

#
# Session exclusion check
#

is_excluded() {
    local session="$1"
    for excl in $EXCLUDED_SESSIONS; do
        # Exact match
        [[ "$session" == "$excl" ]] && return 0
        # Pattern match for coordinator variants
        [[ "$excl" == "claude-0" && "$session" =~ ^claude-0(-acc[12])?$ ]] && return 0
        # Pattern match for overseer variants
        [[ "$excl" == "claude-overseer-1" && "$session" =~ ^claude-overseer ]] && return 0
    done
    return 1
}

#
# Event handling
#

# Called by send-summary.sh after sending a message
register_event() {
    local session="$1"
    local timestamp=$(date +%s)

    is_excluded "$session" && return 0

    echo "{\"session\":\"$session\",\"timestamp\":$timestamp}" > "$STATE_DIR/events/${session}.event"
    log "Event registered for $session"
}

# Called by orchestrator.sh when user replies
register_reply() {
    local session="$1"
    local timestamp=$(date +%s)

    echo "$timestamp" > "$STATE_DIR/replies/${session}.reply"

    # Cancel any active timer
    if [[ -f "$STATE_DIR/timers/${session}.timer" ]]; then
        rm -f "$STATE_DIR/timers/${session}.timer"
        rm -f "$STATE_DIR/events/${session}.event"
        log "Timer cancelled for $session (user replied)"
    fi
}

#
# Timer management
#

start_timer() {
    local session="$1"
    local event_time="$2"
    local now=$(date +%s)

    # Don't start if already running
    [[ -f "$STATE_DIR/timers/${session}.timer" ]] && return 0

    cat > "$STATE_DIR/timers/${session}.timer" << EOF
{
  "session": "$session",
  "event_time": $event_time,
  "timer_start": $now,
  "round": 0,
  "last_round_time": $now
}
EOF
    log "Timer started for $session (event at $(date -r $event_time '+%H:%M:%S'))"
}

get_timer_round() {
    local session="$1"
    local timer_file="$STATE_DIR/timers/${session}.timer"
    [[ -f "$timer_file" ]] || echo "0"
    jq -r '.round // 0' "$timer_file" 2>/dev/null || echo "0"
}

advance_timer_round() {
    local session="$1"
    local new_round="$2"
    local timer_file="$STATE_DIR/timers/${session}.timer"
    local now=$(date +%s)

    [[ -f "$timer_file" ]] || return 1

    local tmp=$(mktemp)
    jq ".round = $new_round | .last_round_time = $now" "$timer_file" > "$tmp" && mv "$tmp" "$timer_file"
}

remove_timer() {
    local session="$1"
    rm -f "$STATE_DIR/timers/${session}.timer"
    rm -f "$STATE_DIR/events/${session}.event"
    log "Timer removed for $session"
}

#
# Terminal snapshots
#

capture_snapshot() {
    local session="$1"
    local round="$2"
    local timestamp=$(date '+%Y%m%d-%H%M%S')
    local snapshot_file="$STATE_DIR/snapshots/${session}-r${round}-${timestamp}.txt"

    if tmux has-session -t "$session" 2>/dev/null; then
        tmux capture-pane -t "$session" -p -S -"$SNAPSHOT_LINES" > "$snapshot_file" 2>/dev/null
        log "Snapshot captured for $session round $round: $snapshot_file"
        echo "$snapshot_file"
    else
        log "Cannot capture snapshot: $session not running"
        echo ""
    fi
}

# Clean old snapshots (keep last 10 per session)
cleanup_snapshots() {
    for session_prefix in $(ls "$STATE_DIR/snapshots/" 2>/dev/null | sed 's/-r[0-9].*//' | sort -u); do
        local count=$(ls "$STATE_DIR/snapshots/${session_prefix}"* 2>/dev/null | wc -l | tr -d ' ')
        if [[ $count -gt 10 ]]; then
            ls -t "$STATE_DIR/snapshots/${session_prefix}"* | tail -n +11 | xargs rm -f
        fi
    done
}

#
# Cross-agent context (from overseer)
#

get_cross_agent_context() {
    local exclude_session="$1"
    local context_file="$STATE_DIR/context/agent-context-map.json"
    local digest_file="$STATE_DIR/context/overseer-digest.md"
    local result=""

    # Try overseer digest first (richer content)
    if [[ -f "$digest_file" ]]; then
        local age=$(($(date +%s) - $(stat -f %m "$digest_file" 2>/dev/null || echo "0")))
        if [[ $age -lt 300 ]]; then
            result=$(cat "$digest_file")
        fi
    fi

    # Fall back to agent context map
    if [[ -z "$result" && -f "$context_file" ]]; then
        local age=$(($(date +%s) - $(stat -f %m "$context_file" 2>/dev/null || echo "0")))
        if [[ $age -lt 300 ]]; then
            # Build summary excluding current session
            result=$(jq -r --arg excl "$exclude_session" '
                to_entries | map(select(.key != $excl)) |
                map("• \(.key): \(.value.state) — \(.value.task // "no task") (cwd: \(.value.cwd // "unknown"))")
                | join("\n")
            ' "$context_file" 2>/dev/null)
        fi
    fi

    # Build a basic context from tmux if no overseer data
    if [[ -z "$result" ]]; then
        result=""
        for session in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -E "^claude-" | sort -t- -k2 -n); do
            [[ "$session" == "$exclude_session" ]] && continue
            is_excluded "$session" && continue

            local output=$(tmux capture-pane -t "$session" -p -S -10 2>/dev/null | tail -5)
            local state="unknown"
            if echo "$output" | grep -qE "esc to interrupt|thinking"; then
                state="working"
            elif echo "$output" | grep -qE "bypass permissions|^❯"; then
                state="idle"
            fi

            local cwd=$(tmux display-message -t "$session" -p "#{pane_current_path}" 2>/dev/null || echo "~")
            cwd="${cwd/#$HOME/~}"
            result+="• $session: $state (cwd: $cwd)"$'\n'
        done
    fi

    echo "$result"
}

#
# Refinement prompts (escalating)
#

inject_refinement() {
    local session="$1"
    local round="$2"
    local snapshot_file="$3"

    # Check session is still running and idle (don't interrupt active work)
    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "$session no longer running, removing timer"
        remove_timer "$session"
        return 1
    fi

    local state_check=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -10)
    if echo "$state_check" | grep -qE "esc to interrupt|thinking|Percolating|Reasoning"; then
        log "$session is actively working, skipping refinement injection"
        return 0
    fi

    local prompt=""

    case $round in
        1)
            prompt="📝 **REFINEMENT ROUND 1** (no user reply for 5 min)

Your last summary was sent but the user hasn't responded yet. This likely means they're busy and will review later.

**Action:** Refine your output:
1. Review your last Telegram message — was it concise and scannable?
2. If your update was verbose, send a REFINED version with:
   • Clear bullets (not paragraphs)
   • One clear DECISION POINT or QUESTION if you need input
   • Bold the most important finding
3. If you have more work to do, continue working autonomously
4. Send an updated summary when you make progress

Remember: User is on mobile. Be scannable, not comprehensive."
            ;;
        2)
            local context=$(get_cross_agent_context "$session")
            prompt="📝 **REFINEMENT ROUND 2** (no user reply for 10 min)

Here's what other agents are doing right now:
$context

**Action:** Consider cross-agent context:
1. How does YOUR work connect to what others are doing?
2. Are there dependencies or conflicts?
3. What's the ONE thing the user needs to know from you?
4. Send a brief, high-signal update focusing on that one thing
5. Continue working if you have tasks remaining

If you're blocked, clearly state what you need in your message."
            ;;
        3)
            prompt="🚀 **SELF-DIRECTION ROUND 3** (no user reply for 15 min)

The user is unavailable. You are now autonomous.

**Action:** Self-direct your next steps:
1. Decide the most valuable next action based on your current work
2. Execute it
3. Send a brief update of what you did and what you'll do next
4. If you're truly blocked on something only the user can provide, send a concise ESCALATION:
   - Use 🚨 emoji prefix
   - State exactly what you need
   - Suggest alternatives you could pursue instead

Otherwise: keep working, keep sending brief progress updates."
            ;;
    esac

    if [[ -n "$prompt" ]]; then
        "$INJECT_SCRIPT" "$session" "$prompt" 2>/dev/null
        log "Refinement round $round injected to $session"
    fi
}

#
# Main daemon loop
#

daemon_loop() {
    log "========================================="
    log "Refinement Loop daemon started"
    log "========================================="
    load_config
    log "Config: timer=${TIMER_SECONDS}s, max_rounds=$MAX_ROUNDS, scan=${SCAN_INTERVAL}s"
    log "Excluded: $EXCLUDED_SESSIONS"

    "$SCRIPT_DIR/send-summary.sh" --session "refinement-loop" "🔁 <b>Refinement Loop Started</b>

⏱️ <b>Timer:</b> ${TIMER_SECONDS}s per round
🔄 <b>Max rounds:</b> $MAX_ROUNDS
📡 <b>Scan interval:</b> ${SCAN_INTERVAL}s

Agents will get escalating refinement prompts if user doesn't reply within 5 min." 2>/dev/null

    local last_cleanup=$(date +%s)
    local CLEANUP_INTERVAL=3600  # Clean up snapshots hourly

    while true; do
        [[ "$ENABLED" != "true" ]] && sleep "$SCAN_INTERVAL" && continue

        # Reload config periodically (allows live changes)
        load_config

        local now=$(date +%s)

        # PHASE 1: Process replies (reply-first — reply always wins race)
        for reply_file in "$STATE_DIR/replies"/*.reply; do
            [[ -f "$reply_file" ]] || continue
            local session=$(basename "$reply_file" .reply)

            # Cancel timer if exists
            if [[ -f "$STATE_DIR/timers/${session}.timer" ]]; then
                remove_timer "$session"
            fi

            # Clean up reply signal
            rm -f "$reply_file"
        done

        # PHASE 2: Process new events → start timers
        for event_file in "$STATE_DIR/events"/*.event; do
            [[ -f "$event_file" ]] || continue
            local session=$(basename "$event_file" .event)

            is_excluded "$session" && continue

            # Skip if session not running
            if ! tmux has-session -t "$session" 2>/dev/null; then
                rm -f "$event_file"
                continue
            fi

            local event_time=$(jq -r '.timestamp // 0' "$event_file" 2>/dev/null || echo "0")

            # Start timer if not already running
            if [[ ! -f "$STATE_DIR/timers/${session}.timer" ]]; then
                start_timer "$session" "$event_time"
            fi
        done

        # PHASE 3: Check active timers → fire refinement rounds
        for timer_file in "$STATE_DIR/timers"/*.timer; do
            [[ -f "$timer_file" ]] || continue
            local session=$(basename "$timer_file" .timer)

            # Check if reply came in since last scan
            if [[ -f "$STATE_DIR/replies/${session}.reply" ]]; then
                remove_timer "$session"
                rm -f "$STATE_DIR/replies/${session}.reply"
                continue
            fi

            # Skip if session not running
            if ! tmux has-session -t "$session" 2>/dev/null; then
                remove_timer "$session"
                continue
            fi

            local current_round=$(jq -r '.round // 0' "$timer_file" 2>/dev/null || echo "0")
            local last_round_time=$(jq -r '.last_round_time // 0' "$timer_file" 2>/dev/null || echo "0")
            local elapsed=$((now - last_round_time))

            # Determine which interval to use based on current round
            local interval
            case $current_round in
                0) interval=$INTERVAL_1 ;;
                1) interval=$INTERVAL_2 ;;
                2) interval=$INTERVAL_3 ;;
                *) interval=$INTERVAL_3 ;;
            esac

            # Check if it's time for next round
            if [[ $elapsed -ge $interval ]]; then
                local next_round=$((current_round + 1))

                if [[ $next_round -le $MAX_ROUNDS ]]; then
                    # Capture terminal snapshot
                    local snapshot=$(capture_snapshot "$session" "$next_round")

                    # Inject refinement prompt
                    inject_refinement "$session" "$next_round" "$snapshot"

                    # Advance timer
                    advance_timer_round "$session" "$next_round"
                else
                    # All rounds fired — agent is now autonomous
                    log "$session: all $MAX_ROUNDS rounds complete, agent is autonomous"
                    remove_timer "$session"
                fi
            fi
        done

        # PHASE 4: Periodic cleanup
        if [[ $((now - last_cleanup)) -ge $CLEANUP_INTERVAL ]]; then
            cleanup_snapshots
            last_cleanup=$now
        fi

        sleep "$SCAN_INTERVAL"
    done
}

#
# Commands
#

cmd_start() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Refinement loop already running (PID $pid)"
            return 0
        fi
    fi

    if tmux has-session -t refinement-loop 2>/dev/null; then
        echo "Refinement loop tmux session already exists"
        return 0
    fi

    tmux new-session -d -s refinement-loop "$SCRIPT_DIR/refinement-loop.sh daemon"
    sleep 1
    local pid=$(tmux list-panes -t refinement-loop -F "#{pane_pid}" 2>/dev/null | head -1)
    echo "$pid" > "$PID_FILE"
    echo "Refinement loop started (PID: $pid)"
}

cmd_stop() {
    tmux kill-session -t refinement-loop 2>/dev/null
    rm -f "$PID_FILE"
    echo "Refinement loop stopped"
}

cmd_status() {
    local running="false"
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        kill -0 "$pid" 2>/dev/null && running="true"
    fi
    tmux has-session -t refinement-loop 2>/dev/null && running="true"

    if [[ "$running" == "true" ]]; then
        echo "🟢 Refinement loop: Running"
    else
        echo "🔴 Refinement loop: Stopped"
    fi

    # Show active timers
    local timer_count=0
    echo ""
    echo "Active timers:"
    for timer_file in "$STATE_DIR/timers"/*.timer; do
        [[ -f "$timer_file" ]] || continue
        local session=$(basename "$timer_file" .timer)
        local round=$(jq -r '.round // 0' "$timer_file" 2>/dev/null)
        local last_time=$(jq -r '.last_round_time // 0' "$timer_file" 2>/dev/null)
        local elapsed=$(($(date +%s) - last_time))
        echo "  • $session: round $round/$MAX_ROUNDS (${elapsed}s since last)"
        timer_count=$((timer_count + 1))
    done
    [[ $timer_count -eq 0 ]] && echo "  (none)"

    # Show pending events
    local event_count=0
    echo ""
    echo "Pending events:"
    for event_file in "$STATE_DIR/events"/*.event; do
        [[ -f "$event_file" ]] || continue
        local session=$(basename "$event_file" .event)
        echo "  • $session"
        event_count=$((event_count + 1))
    done
    [[ $event_count -eq 0 ]] && echo "  (none)"
}

cmd_trigger() {
    local session="$1"
    [[ -z "$session" ]] && echo "Usage: refinement-loop.sh trigger <session>" && return 1

    load_config
    register_event "$session"
    echo "Manually triggered refinement for $session"
}

cmd_cancel() {
    local session="$1"
    [[ -z "$session" ]] && echo "Usage: refinement-loop.sh cancel <session>" && return 1

    register_reply "$session"
    echo "Cancelled refinement for $session"
}

cmd_config() {
    load_config
    echo "Refinement Loop Configuration:"
    echo "  Enabled: $ENABLED"
    echo "  Timer: ${TIMER_SECONDS}s"
    echo "  Max rounds: $MAX_ROUNDS"
    echo "  Intervals: ${INTERVAL_1}s / ${INTERVAL_2}s / ${INTERVAL_3}s"
    echo "  Scan interval: ${SCAN_INTERVAL}s"
    echo "  Snapshot lines: $SNAPSHOT_LINES"
    echo "  Self-direct round: $AUTO_SELF_DIRECT_ROUND"
    echo "  Excluded: $EXCLUDED_SESSIONS"
}

cmd_help() {
    cat << 'EOF'
🔁 Refinement Loop Daemon

Usage: refinement-loop.sh <command> [args]

Commands:
  start              Start daemon in tmux session
  stop               Stop daemon
  status             Show active timers and status
  daemon             Run daemon loop (internal)
  trigger <session>  Manually trigger refinement for session
  cancel <session>   Cancel timer for session
  config             Show current configuration

How it works:
  1. Agent sends summary → event registered
  2. 5-min timer starts
  3. User replies → timer cancelled
  4. No reply → Round 1: "Refine your output"
  5. +5 min → Round 2: "Cross-agent context + refine"
  6. +5 min → Round 3: "Self-direct, you're autonomous"
  7. After round 3 → timer removed, agent works independently

Config: ~/.claude/refinement-loop/refinement-config.json
Logs: ~/.claude/telegram-orchestrator/logs/refinement-loop.log
EOF
}

#
# Main
#

case "${1:-help}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    daemon)  daemon_loop ;;
    trigger) cmd_trigger "$2" ;;
    cancel)  cmd_cancel "$2" ;;
    config)  cmd_config ;;
    help|*)  cmd_help ;;
esac
