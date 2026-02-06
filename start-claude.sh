#!/bin/bash
# start-claude.sh - Start a new Claude Code session in tmux
# Usage: start-claude.sh [initial_prompt] [working_dir]
#        start-claude.sh --resume <session-id> [working_dir]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"

# Account management
ACCOUNT_DIR="$HOME/.claude/account-manager"
get_active_account() {
    cat "$ACCOUNT_DIR/active-account" 2>/dev/null || echo "1"
}

setup_account_env() {
    local account="${1:-$(get_active_account)}"
    if [[ "$account" == "2" ]]; then
        export CLAUDE_CONFIG_DIR="$HOME/.claude-account2"
        if [[ ! -d "$CLAUDE_CONFIG_DIR" ]]; then
            echo "Warning: Account 2 not configured. Run: CLAUDE_CONFIG_DIR=~/.claude-account2 claude login"
        fi
    fi
}

# Exact session name check (tmux has-session does prefix matching which causes bugs)
session_exists() {
    local name="$1"
    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -qx "$name"
}

# Parse arguments
RESUME_SESSION=""
RESUME_QUERY=""
INITIAL_PROMPT=""
WORKING_DIR="$HOME"
COORDINATOR_MODE=""
ACCOUNT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume)
            RESUME_SESSION="$2"
            shift 2
            ;;
        --query)
            RESUME_QUERY="$2"
            shift 2
            ;;
        --coordinator)
            COORDINATOR_MODE="true"
            shift
            ;;
        --account)
            ACCOUNT_OVERRIDE="$2"
            shift 2
            ;;
        *)
            if [[ -z "$INITIAL_PROMPT" ]]; then
                INITIAL_PROMPT="$1"
            else
                WORKING_DIR="$1"
            fi
            shift
            ;;
    esac
done

SESSIONS_DIR="$SCRIPT_DIR/sessions"
mkdir -p "$SESSIONS_DIR"

# Determine active account FIRST (needed for session naming)
# If no override, use smart-rotate for intelligent selection; fall back to active-account file
SMART_ROTATE="$HOME/.claude/account-manager/smart-rotate.sh"
if [[ -n "$ACCOUNT_OVERRIDE" ]]; then
    ACTIVE_ACCOUNT="$ACCOUNT_OVERRIDE"
elif [[ -x "$SMART_ROTATE" ]]; then
    ACTIVE_ACCOUNT=$("$SMART_ROTATE" account-number 2>/dev/null)
    [[ -z "$ACTIVE_ACCOUNT" ]] && ACTIVE_ACCOUNT=$(get_active_account)
else
    ACTIVE_ACCOUNT=$(get_active_account)
fi
setup_account_env "$ACTIVE_ACCOUNT"

# Account 1 = no suffix (default), Account 2 = -acc2 suffix
if [[ "$ACTIVE_ACCOUNT" == "2" ]]; then
    ACCOUNT_SUFFIX="-acc2"
else
    ACCOUNT_SUFFIX=""  # Account 1 has no suffix
fi

# Determine session name (now includes account suffix)
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    # Coordinator: claude-0-accN
    SESSION_NAME="claude-0${ACCOUNT_SUFFIX}"

    # Check if already running (exact match)
    if session_exists "$SESSION_NAME"; then
        echo "Coordinator $SESSION_NAME already running"
        exit 0
    fi
else
    # Find next available session number (start from 1, 0 is reserved for coordinator)
    # Check both accounts to avoid number collisions in tmux ls output
    SESSION_NUM=1
    while true; do
        # Check if session exists with current account suffix (exact match)
        if session_exists "claude-${SESSION_NUM}${ACCOUNT_SUFFIX}"; then
            SESSION_NUM=$((SESSION_NUM + 1))
        else
            break
        fi
        if [[ $SESSION_NUM -gt $MAX_SESSIONS ]]; then
            echo "Error: Maximum sessions ($MAX_SESSIONS) reached"
            "$SCRIPT_DIR/notify.sh" "error" "system" "Max sessions reached ($MAX_SESSIONS)"
            exit 1
        fi
    done
    SESSION_NAME="claude-${SESSION_NUM}${ACCOUNT_SUFFIX}"
fi

# Create tmux session with account environment
if [[ "$ACTIVE_ACCOUNT" == "2" ]]; then
    tmux new-session -d -s "$SESSION_NAME" -c "$WORKING_DIR" -e "CLAUDE_CONFIG_DIR=$HOME/.claude-account2"
else
    tmux new-session -d -s "$SESSION_NAME" -c "$WORKING_DIR"
fi

# Enable session logging (defense-in-depth, also handled by tmux session-created hook)
tmux pipe-pane -t "$SESSION_NAME" "exec $HOME/.claude/scripts/tmux-log-pipe.sh '$SESSION_NAME'" 2>/dev/null || true

# Start Claude - coordinator, resuming, or fresh
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    # Start coordinator with special system prompt
    COORDINATOR_MD="$SCRIPT_DIR/coordinator-claude.md"
    tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions --append-system-prompt \"\$(cat $COORDINATOR_MD)\""
    tmux send-keys -t "$SESSION_NAME" -H 0d
elif [[ -n "$RESUME_SESSION" ]]; then
    # Resume existing session
    tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions --resume $RESUME_SESSION"
    tmux send-keys -t "$SESSION_NAME" -H 0d
else
    # Start fresh Claude
    tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions"
    tmux send-keys -t "$SESSION_NAME" -H 0d

    # Send initial prompt if provided
    if [[ -n "$INITIAL_PROMPT" ]]; then
        sleep 5
        tmux send-keys -t "$SESSION_NAME" "$INITIAL_PROMPT"
        tmux send-keys -t "$SESSION_NAME" -H 0d
    fi
fi

# Record session info
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR",
  "role": "coordinator",
  "account": $ACTIVE_ACCOUNT
}
EOF
elif [[ -n "$RESUME_SESSION" ]]; then
    cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR",
  "resumed_from": "$RESUME_SESSION",
  "resume_query": "$RESUME_QUERY",
  "account": $ACTIVE_ACCOUNT
}
EOF
else
    cat > "$SESSIONS_DIR/$SESSION_NAME" << EOF
{
  "name": "$SESSION_NAME",
  "started": "$(date -Iseconds)",
  "cwd": "$WORKING_DIR",
  "task": "${INITIAL_PROMPT:0:200}",
  "status": "active",
  "account": $ACTIVE_ACCOUNT
}
EOF
fi

# Session monitor disabled - using queue-based summaries instead
# nohup "$SCRIPT_DIR/session-monitor.sh" "$SESSION_NAME" >> "$SCRIPT_DIR/logs/monitor-$SESSION_NAME.log" 2>&1 &
# echo $! > "$SESSIONS_DIR/$SESSION_NAME.monitor.pid"

# Notify
if [[ "$COORDINATOR_MODE" == "true" ]]; then
    "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "🎯 Coordinator started
Ready to receive messages
Use: tmux attach -t $SESSION_NAME"
    echo "Started coordinator $SESSION_NAME"
elif [[ -n "$RESUME_SESSION" ]]; then
    if [[ -n "$RESUME_QUERY" ]]; then
        "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "🔄 Resumed: \"$RESUME_QUERY\"
Session: ${RESUME_SESSION:0:8}...
Use: tmux attach -t $SESSION_NAME"
    else
        "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "🔄 Resumed session ${RESUME_SESSION:0:8}...
Use: tmux attach -t $SESSION_NAME"
    fi
    echo "Started $SESSION_NAME (resumed from $RESUME_SESSION)"
else
    "$SCRIPT_DIR/notify.sh" "new" "$SESSION_NAME" "Started in $WORKING_DIR
Use: tmux attach -t $SESSION_NAME"
    echo "Started $SESSION_NAME"
fi
