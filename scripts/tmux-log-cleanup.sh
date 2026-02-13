#!/bin/bash
# tmux-log-cleanup.sh - Remove tmux log files older than N days
# Usage: tmux-log-cleanup.sh [days]  (default: 7)
# Cron: 0 3 * * * ~/.claude/scripts/tmux-log-cleanup.sh

set -euo pipefail

LOG_DIR="$HOME/.claude/logs/tmux"
DAYS="${1:-7}"

if [[ ! -d "$LOG_DIR" ]]; then
    exit 0
fi

DELETED=0
while IFS= read -r -d '' file; do
    rm "$file"
    DELETED=$((DELETED + 1))
done < <(find "$LOG_DIR" -name "*.log" -mtime +"$DAYS" -print0)

if [[ $DELETED -gt 0 ]]; then
    echo "Cleaned up $DELETED log files older than $DAYS days"
fi
