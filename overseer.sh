#!/bin/bash
# overseer.sh - Cross-agent awareness daemon for orchestrator v2
#
# Scans all active sessions, builds a context map, manages overseer
# Claude agent sessions, and produces digests for refinement round 2+.
#
# Usage:
#   overseer.sh start    - Start daemon in tmux
#   overseer.sh stop     - Stop daemon
#   overseer.sh status   - Show current agent context map
#   overseer.sh daemon   - Run daemon loop (internal)
#   overseer.sh scan     - Run one-shot scan and print context
#   overseer.sh digest   - Show latest overseer digest

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.claude/refinement-loop"
CONTEXT_DIR="$STATE_DIR/context"
CONFIG_FILE="$STATE_DIR/refinement-config.json"
LOG_FILE="$SCRIPT_DIR/logs/overseer.log"
PID_FILE="$STATE_DIR/overseer.pid"
CONTEXT_MAP="$CONTEXT_DIR/agent-context-map.json"
DIGEST_FILE="$CONTEXT_DIR/overseer-digest.md"
SESSIONS_DIR="$SCRIPT_DIR/sessions"

mkdir -p "$CONTEXT_DIR" "$SCRIPT_DIR/logs"

[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

#
# Logging
#

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [overseer] $*" | tee -a "$LOG_FILE"
}

#
# Configuration
#

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        SCAN_INTERVAL=$(jq -r '.context_scan_interval // 60' "$CONFIG_FILE")
        EXCLUDED_SESSIONS=$(jq -r '.excluded_sessions // [] | .[]' "$CONFIG_FILE" 2>/dev/null)
    else
        SCAN_INTERVAL=60
        EXCLUDED_SESSIONS=""
    fi
}

is_excluded() {
    local session="$1"
    for excl in $EXCLUDED_SESSIONS; do
        [[ "$session" == "$excl" ]] && return 0
        [[ "$excl" == "claude-0" && "$session" =~ ^claude-0(-acc[12])?$ ]] && return 0
        [[ "$excl" == "claude-overseer-1" && "$session" =~ ^claude-overseer ]] && return 0
    done
    return 1
}

#
# Session scanning
#

detect_session_state() {
    local session="$1"
    local output=$(tmux capture-pane -t "$session" -p 2>/dev/null)
    local last_lines=$(echo "$output" | tail -15)

    [[ -z "$output" ]] && echo "dead" && return

    # Thinking/working patterns
    if echo "$last_lines" | grep -qE "esc to interrupt|thinking|Percolating|Reasoning|Reading|Writing"; then
        echo "working"
        return
    fi

    # Idle patterns
    if echo "$last_lines" | grep -qE "bypass permissions|^❯"; then
        echo "idle"
        return
    fi

    # Stuck patterns
    if echo "$last_lines" | grep -qE "Would you like to proceed|Y/n|\[y/N\]"; then
        echo "stuck:approval"
        return
    fi
    if echo "$last_lines" | grep -qE "↵ send|Press up to edit"; then
        echo "stuck:input_pending"
        return
    fi
    if echo "$last_lines" | grep -qE "plan mode on"; then
        echo "stuck:plan_mode"
        return
    fi

    # Rate limited
    if echo "$output" | grep -qE "You've hit your limit|You're out of extra usage|rate limit"; then
        echo "rate_limited"
        return
    fi

    echo "unknown"
}

get_session_task() {
    local session="$1"

    # Try session metadata file first
    local meta_file="$SESSIONS_DIR/$session"
    if [[ -f "$meta_file" ]]; then
        local task=$(jq -r '.task // ""' "$meta_file" 2>/dev/null)
        [[ -n "$task" && "$task" != "null" ]] && echo "${task:0:120}" && return
    fi

    # Try RALPH task file
    local task_file="$HOME/.claude/handoffs/${session}-task.md"
    if [[ -f "$task_file" ]]; then
        local task_name=$(head -1 "$task_file" | sed 's/^# Task: //')
        [[ -n "$task_name" ]] && echo "${task_name:0:120}" && return
    fi

    echo ""
}

get_session_context_pct() {
    local session="$1"
    local output=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null)
    local pct=$(echo "$output" | grep -oE "[0-9]+% \([0-9]+k\)" | tail -1 | grep -oE "^[0-9]+")
    echo "${pct:-0}"
}

get_recent_activity() {
    local session="$1"
    local output=$(tmux capture-pane -t "$session" -p -S -30 2>/dev/null)

    # Extract recent tool actions
    local actions=$(echo "$output" | grep -E "^⏺|✔|✓|Bash\(|Read |Edit |Task\(" | tail -3 | sed 's/^/    /')
    echo "$actions"
}

#
# Context map building
#

build_context_map() {
    local map="{}"
    local session_count=0

    for session in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -E "^claude-" | sort -t- -k2 -n); do
        is_excluded "$session" && continue

        # Skip if not a Claude session
        if ! tmux has-session -t "$session" 2>/dev/null; then
            continue
        fi

        local state=$(detect_session_state "$session")
        local task=$(get_session_task "$session")
        local cwd=$(tmux display-message -t "$session" -p "#{pane_current_path}" 2>/dev/null || echo "$HOME")
        cwd="${cwd/#$HOME/\~}"
        local context_pct=$(get_session_context_pct "$session")
        local activity=$(get_recent_activity "$session")

        # Build JSON entry
        map=$(echo "$map" | jq --arg s "$session" \
            --arg state "$state" \
            --arg task "$task" \
            --arg cwd "$cwd" \
            --argjson ctx "${context_pct:-0}" \
            --arg activity "$activity" \
            '. + {($s): {"state": $state, "task": $task, "cwd": $cwd, "context_pct": $ctx, "recent_activity": $activity, "scanned_at": now}}' 2>/dev/null)

        session_count=$((session_count + 1))
    done

    echo "$map" > "$CONTEXT_MAP"
    log "Context map built: $session_count sessions"
}

#
# Digest generation
#

generate_digest() {
    [[ ! -f "$CONTEXT_MAP" ]] && return

    local digest="# Overseer Digest
Generated: $(date '+%Y-%m-%d %H:%M:%S')

## Active Sessions

"
    local working_count=0
    local idle_count=0
    local stuck_count=0
    local stuck_sessions=""

    # Parse context map
    local sessions=$(jq -r 'keys[]' "$CONTEXT_MAP" 2>/dev/null)
    for session in $sessions; do
        local state=$(jq -r --arg s "$session" '.[$s].state' "$CONTEXT_MAP" 2>/dev/null)
        local task=$(jq -r --arg s "$session" '.[$s].task' "$CONTEXT_MAP" 2>/dev/null)
        local cwd=$(jq -r --arg s "$session" '.[$s].cwd' "$CONTEXT_MAP" 2>/dev/null)
        local ctx=$(jq -r --arg s "$session" '.[$s].context_pct' "$CONTEXT_MAP" 2>/dev/null)

        local icon="❓"
        case "$state" in
            working) icon="⏳"; working_count=$((working_count + 1)) ;;
            idle) icon="🟢"; idle_count=$((idle_count + 1)) ;;
            stuck:*) icon="🔴"; stuck_count=$((stuck_count + 1)); stuck_sessions+="$session " ;;
            rate_limited) icon="⚠️"; stuck_count=$((stuck_count + 1)); stuck_sessions+="$session " ;;
            dead) icon="💀" ;;
            *) icon="❓"; idle_count=$((idle_count + 1)) ;;
        esac

        local ctx_warn=""
        [[ $ctx -ge 50 ]] && ctx_warn=" ⚠️"

        digest+="$icon **$session** ($state) — ctx: ${ctx}%${ctx_warn}
"
        [[ -n "$task" && "$task" != "null" && "$task" != "" ]] && digest+="   Task: $task
"
        digest+="   Dir: $cwd
"
    done

    digest+="
## Summary
- Working: $working_count
- Idle: $idle_count
- Stuck/Issues: $stuck_count
"

    if [[ $stuck_count -gt 0 ]]; then
        digest+="
## Attention Needed
Sessions requiring intervention: $stuck_sessions
"
    fi

    # Detect potential cross-agent issues
    local all_cwds=$(jq -r '[.[].cwd] | sort | group_by(.) | map(select(length > 1) | {dir: .[0], count: length}) | .[]? | "\(.dir) (\(.count) agents)"' "$CONTEXT_MAP" 2>/dev/null)
    if [[ -n "$all_cwds" ]]; then
        digest+="
## Shared Directories (potential conflicts)
$all_cwds
"
    fi

    echo "$digest" > "$DIGEST_FILE"
    log "Digest generated"
}

#
# Overseer agent management
#

start_overseer_agent() {
    local overseer_session="claude-overseer-1"

    if tmux has-session -t "$overseer_session" 2>/dev/null; then
        log "Overseer agent already running: $overseer_session"
        return 0
    fi

    local overseer_md="$SCRIPT_DIR/overseer-claude.md"
    if [[ ! -f "$overseer_md" ]]; then
        log "Overseer system prompt not found: $overseer_md"
        return 1
    fi

    # Build session-specific prompt
    local session_prompt="/tmp/claude-prompt-${overseer_session}.md"
    sed "s/{SESSION_IDENTITY}/$overseer_session/g" "$overseer_md" > "$session_prompt"

    # Determine account
    local active_account=$(cat "$HOME/.claude/account-manager/active-account" 2>/dev/null || echo "1")
    if [[ "$active_account" == "2" ]]; then
        tmux new-session -d -s "$overseer_session" -c "$HOME" -e "CLAUDE_CONFIG_DIR=$HOME/.claude-account2"
    else
        tmux new-session -d -s "$overseer_session" -c "$HOME"
    fi

    # Enable logging
    tmux pipe-pane -t "$overseer_session" "exec $HOME/.claude/scripts/tmux-log-pipe.sh '$overseer_session'" 2>/dev/null || true

    sleep 1
    tmux send-keys -t "$overseer_session" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $session_prompt)\""
    tmux send-keys -t "$overseer_session" -H 0d

    log "Overseer agent started: $overseer_session"
    return 0
}

feed_overseer() {
    local overseer_session="claude-overseer-1"

    if ! tmux has-session -t "$overseer_session" 2>/dev/null; then
        return 0
    fi

    # Check if overseer is idle (ready for input)
    local overseer_output=$(tmux capture-pane -t "$overseer_session" -p 2>/dev/null | tail -10)
    if echo "$overseer_output" | grep -qE "esc to interrupt|thinking|Reasoning"; then
        log "Overseer is busy, skipping feed"
        return 0
    fi

    local context_map_content=""
    if [[ -f "$CONTEXT_MAP" ]]; then
        context_map_content=$(cat "$CONTEXT_MAP")
    fi

    local feed_prompt="Here is the current agent context map. Analyze it and produce a brief digest:

\`\`\`json
$context_map_content
\`\`\`

Tasks:
1. Identify any cross-agent dependencies or conflicts
2. Flag sessions that need attention (stuck, high context, conflicting dirs)
3. Suggest routing: which idle agents could help stuck ones?
4. Write a 5-line summary for the user

Save your analysis to: $DIGEST_FILE

Keep it brief — you are a lightweight overseer, not an implementer."

    "$SCRIPT_DIR/inject-prompt.sh" "$overseer_session" "$feed_prompt" 2>/dev/null
    log "Fed context to overseer agent"
}

#
# Main daemon loop
#

daemon_loop() {
    log "========================================="
    log "Overseer daemon started"
    log "========================================="
    load_config
    log "Config: scan_interval=${SCAN_INTERVAL}s"

    "$SCRIPT_DIR/send-summary.sh" --session "overseer" "👁️ <b>Overseer Daemon Started</b>

🔍 <b>Scan interval:</b> ${SCAN_INTERVAL}s
📊 Context map: <code>~/.claude/refinement-loop/context/agent-context-map.json</code>
📝 Digest: <code>~/.claude/refinement-loop/context/overseer-digest.md</code>" 2>/dev/null

    local last_feed=0
    local FEED_INTERVAL=300  # Feed overseer agent every 5 min

    while true; do
        load_config
        local now=$(date +%s)

        # Build context map
        build_context_map

        # Generate digest (lightweight, always)
        generate_digest

        # Feed overseer agent periodically (if running)
        if [[ $((now - last_feed)) -ge $FEED_INTERVAL ]]; then
            if tmux has-session -t "claude-overseer-1" 2>/dev/null; then
                feed_overseer
            fi
            last_feed=$now
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
            echo "Overseer already running (PID $pid)"
            return 0
        fi
    fi

    if tmux has-session -t overseer-daemon 2>/dev/null; then
        echo "Overseer tmux session already exists"
        return 0
    fi

    tmux new-session -d -s overseer-daemon "$SCRIPT_DIR/overseer.sh daemon"
    sleep 1
    local pid=$(tmux list-panes -t overseer-daemon -F "#{pane_pid}" 2>/dev/null | head -1)
    echo "$pid" > "$PID_FILE"
    echo "Overseer daemon started (PID: $pid)"
}

cmd_stop() {
    tmux kill-session -t overseer-daemon 2>/dev/null
    rm -f "$PID_FILE"
    echo "Overseer daemon stopped"
}

cmd_start_agent() {
    start_overseer_agent
    echo "Overseer agent started"
}

cmd_stop_agent() {
    tmux kill-session -t "claude-overseer-1" 2>/dev/null
    echo "Overseer agent stopped"
}

cmd_status() {
    # Daemon status
    local running="false"
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        kill -0 "$pid" 2>/dev/null && running="true"
    fi
    tmux has-session -t overseer-daemon 2>/dev/null && running="true"

    if [[ "$running" == "true" ]]; then
        echo "🟢 Overseer daemon: Running"
    else
        echo "🔴 Overseer daemon: Stopped"
    fi

    # Agent status
    if tmux has-session -t "claude-overseer-1" 2>/dev/null; then
        echo "🟢 Overseer agent: Running (claude-overseer-1)"
    else
        echo "🔴 Overseer agent: Stopped"
    fi

    # Context map age
    if [[ -f "$CONTEXT_MAP" ]]; then
        local age=$(($(date +%s) - $(stat -f %m "$CONTEXT_MAP" 2>/dev/null || echo "0")))
        echo ""
        echo "Context map: ${age}s old"
        echo "Sessions tracked: $(jq 'length' "$CONTEXT_MAP" 2>/dev/null || echo "0")"
    else
        echo ""
        echo "Context map: not yet generated"
    fi

    # Digest age
    if [[ -f "$DIGEST_FILE" ]]; then
        local age=$(($(date +%s) - $(stat -f %m "$DIGEST_FILE" 2>/dev/null || echo "0")))
        echo "Digest: ${age}s old"
    fi
}

cmd_scan() {
    load_config
    build_context_map
    generate_digest

    echo "=== Agent Context Map ==="
    jq '.' "$CONTEXT_MAP" 2>/dev/null || echo "(empty)"
    echo ""
    echo "=== Digest ==="
    cat "$DIGEST_FILE" 2>/dev/null || echo "(none)"
}

cmd_digest() {
    if [[ -f "$DIGEST_FILE" ]]; then
        cat "$DIGEST_FILE"
    else
        echo "No digest available. Run: overseer.sh scan"
    fi
}

cmd_help() {
    cat << 'EOF'
👁️ Overseer Daemon - Cross-Agent Awareness

Usage: overseer.sh <command> [args]

Daemon Commands:
  start              Start overseer daemon in tmux
  stop               Stop overseer daemon
  status             Show daemon + agent status

Agent Commands:
  start-agent        Start overseer Claude agent (claude-overseer-1)
  stop-agent         Stop overseer Claude agent

Information:
  scan               Run one-shot scan and print context map + digest
  digest             Show latest overseer digest

How it works:
  1. Scans all claude-* tmux sessions every 60s
  2. Builds agent-context-map.json (state, task, cwd, context%)
  3. Generates overseer-digest.md (summary, issues, conflicts)
  4. Optionally feeds context to an overseer Claude agent
  5. Refinement loop uses this context in round 2+ prompts

Config: ~/.claude/refinement-loop/refinement-config.json
Context map: ~/.claude/refinement-loop/context/agent-context-map.json
Digest: ~/.claude/refinement-loop/context/overseer-digest.md
EOF
}

#
# Main
#

case "${1:-help}" in
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    start-agent) cmd_start_agent ;;
    stop-agent)  cmd_stop_agent ;;
    status)      cmd_status ;;
    scan)        cmd_scan ;;
    digest)      cmd_digest ;;
    daemon)      daemon_loop ;;
    help|*)      cmd_help ;;
esac
