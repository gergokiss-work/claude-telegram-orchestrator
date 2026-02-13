#!/bin/bash
# tmux-log.sh - Search and retrieve tmux session logs
# Usage:
#   tmux-log.sh search <pattern> [--session <name>] [--today] [--days N] [-i] [-C N]
#   tmux-log.sh tail <session> [--lines N]
#   tmux-log.sh list [--sessions] [--today]
#   tmux-log.sh clip <pattern> [--session <name>] [--lines N]
#   tmux-log.sh enable [session]
#   tmux-log.sh status

set -euo pipefail

LOG_DIR="$HOME/.claude/logs/tmux"

usage() {
    cat <<'USAGE'
tmux-log.sh - Search and retrieve tmux session logs

SUBCOMMANDS:
  search <pattern>  Search logs with grep (regex supported)
    --session NAME  Restrict to specific session
    --today         Only search today's logs
    --days N        Search last N days (default: all)
    -i              Case-insensitive search
    -C N            Context lines (default: 2)

  tail <session>    Show last N lines of a session's most recent log
    --lines N       Number of lines (default: 50)

  list              List available log files
    --sessions      List unique session names only
    --today         Only show today's logs

  clip <pattern>    Search and copy results to clipboard (pbcopy)
    --session NAME  Restrict to specific session
    --lines N       Max lines to copy (default: 100)

  enable [session]  Enable pipe-pane logging for session (default: current)

  status            Show logging status for all active sessions

EXAMPLES:
  tmux-log.sh search "error" --session claude-3 --today
  tmux-log.sh tail claude-1 --lines 100
  tmux-log.sh clip "API_ENDPOINT" --session backend
  tmux-log.sh list --sessions
  tmux-log.sh enable claude-5
USAGE
    exit 1
}

mkdir -p "$LOG_DIR"

# Build file list based on session and date filters
build_file_list() {
    local session_filter="$1"
    local date_filter="$2"
    local days="$3"
    local files=()

    if [[ -n "$session_filter" && -n "$date_filter" ]]; then
        for f in "$LOG_DIR/${session_filter}_${date_filter}"*.log; do
            [[ -f "$f" ]] && files+=("$f")
        done
    elif [[ -n "$session_filter" ]]; then
        if [[ -n "$days" ]]; then
            for i in $(seq 0 "$((days - 1))"); do
                local d
                d=$(date -v"-${i}d" '+%Y-%m-%d')
                for f in "$LOG_DIR/${session_filter}_${d}"*.log; do
                    [[ -f "$f" ]] && files+=("$f")
                done
            done
        else
            for f in "$LOG_DIR/${session_filter}_"*.log; do
                [[ -f "$f" ]] && files+=("$f")
            done
        fi
    elif [[ -n "$date_filter" ]]; then
        for f in "$LOG_DIR"/*_"${date_filter}"*.log; do
            [[ -f "$f" ]] && files+=("$f")
        done
    elif [[ -n "$days" ]]; then
        for i in $(seq 0 "$((days - 1))"); do
            local d
            d=$(date -v"-${i}d" '+%Y-%m-%d')
            for f in "$LOG_DIR"/*_"${d}"*.log; do
                [[ -f "$f" ]] && files+=("$f")
            done
        done
    else
        for f in "$LOG_DIR"/*.log; do
            [[ -f "$f" ]] && files+=("$f")
        done
    fi

    # Return only existing files
    for f in "${files[@]}"; do
        [[ -f "$f" ]] && echo "$f"
    done
}

COMMAND="${1:-}"
shift 2>/dev/null || true

case "$COMMAND" in
    search)
        PATTERN="${1:-}"
        [[ -z "$PATTERN" ]] && { echo "Error: search pattern required"; usage; }
        shift

        SESSION_FILTER=""
        DATE_FILTER=""
        DAYS=""
        CASE_FLAG=""
        CONTEXT=2

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --session|-s) SESSION_FILTER="$2"; shift 2 ;;
                --today)      DATE_FILTER=$(date '+%Y-%m-%d'); shift ;;
                --days)       DAYS="$2"; shift 2 ;;
                -i)           CASE_FLAG="-i"; shift ;;
                -C)           CONTEXT="$2"; shift 2 ;;
                *)            shift ;;
            esac
        done

        FILES=$(build_file_list "$SESSION_FILTER" "$DATE_FILTER" "$DAYS")
        if [[ -z "$FILES" ]]; then
            echo "No log files found matching criteria"
            exit 0
        fi

        echo "$FILES" | xargs grep $CASE_FLAG -n -C "$CONTEXT" --color=never -H "$PATTERN" 2>/dev/null || echo "No matches found"
        ;;

    tail)
        SESSION="${1:-}"
        [[ -z "$SESSION" ]] && { echo "Error: session name required"; usage; }
        shift 2>/dev/null || true

        LINES=50
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --lines|-n) LINES="$2"; shift 2 ;;
                *)          shift ;;
            esac
        done

        # Find most recent log for this session
        LATEST=$(ls -t "$LOG_DIR/${SESSION}_"*.log 2>/dev/null | head -1)
        if [[ -z "$LATEST" ]]; then
            echo "No logs found for session: $SESSION"
            exit 1
        fi

        echo "=== $LATEST (last $LINES lines) ==="
        tail -n "$LINES" "$LATEST"
        ;;

    list)
        MODE="files"
        DATE_FILTER=""

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --sessions) MODE="sessions"; shift ;;
                --today)    DATE_FILTER=$(date '+%Y-%m-%d'); shift ;;
                *)          shift ;;
            esac
        done

        if [[ "$MODE" == "sessions" ]]; then
            ls "$LOG_DIR"/*.log 2>/dev/null | xargs -I{} basename {} | sed 's/_[0-9-]*\.log$//' | sort -u
        elif [[ -n "$DATE_FILTER" ]]; then
            ls -lh "$LOG_DIR"/*_"${DATE_FILTER}"*.log 2>/dev/null || echo "No logs for $DATE_FILTER"
        else
            ls -lht "$LOG_DIR"/*.log 2>/dev/null | head -30 || echo "No logs found"
        fi
        ;;

    clip)
        PATTERN="${1:-}"
        [[ -z "$PATTERN" ]] && { echo "Error: search pattern required"; usage; }
        shift

        SESSION_FILTER=""
        MAX_LINES=100

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --session|-s) SESSION_FILTER="$2"; shift 2 ;;
                --lines|-n)   MAX_LINES="$2"; shift 2 ;;
                *)            shift ;;
            esac
        done

        FILES=$(build_file_list "$SESSION_FILTER" "" "")
        if [[ -z "$FILES" ]]; then
            echo "No log files found"
            exit 0
        fi

        RESULTS=$(echo "$FILES" | xargs grep -n --color=never -H "$PATTERN" 2>/dev/null | head -n "$MAX_LINES")
        if [[ -n "$RESULTS" ]]; then
            echo "$RESULTS" | pbcopy
            MATCH_COUNT=$(echo "$RESULTS" | wc -l | tr -d ' ')
            echo "Copied $MATCH_COUNT lines to clipboard"
        else
            echo "No matches found"
        fi
        ;;

    enable)
        TARGET="${1:-$(tmux display-message -p '#S' 2>/dev/null)}"
        if [[ -z "$TARGET" ]]; then
            echo "Error: not in a tmux session and no session name provided"
            exit 1
        fi

        tmux pipe-pane -t "$TARGET" "exec $HOME/.claude/scripts/tmux-log-pipe.sh '$TARGET'"
        echo "Logging enabled for session: $TARGET → $LOG_DIR/${TARGET}_$(date '+%Y-%m-%d-%H%M').log"
        ;;

    status)
        echo "=== tmux Session Logging Status ==="
        echo ""
        for sess in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
            TODAY=$(date '+%Y-%m-%d')
            # Find any log file for this session from today
            LATEST=$(ls -t "$LOG_DIR/${sess}_${TODAY}"*.log 2>/dev/null | head -1)
            if [[ -n "$LATEST" && -f "$LATEST" ]]; then
                SIZE=$(ls -lh "$LATEST" | awk '{print $5}')
                LINES=$(wc -l < "$LATEST" | tr -d ' ')
                echo "  $sess: LOGGING ($SIZE, $LINES lines) → $(basename "$LATEST")"
            else
                echo "  $sess: NOT LOGGING"
            fi
        done
        ;;

    *)
        usage
        ;;
esac
