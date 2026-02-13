#!/usr/bin/env bash
# Get current timestamp for progress logging
# Usage: bash .claude/scripts/get-timestamp.sh [format]
#
# Formats:
#   time     - HH:MM (default, for milestone entries)
#   date     - YYYY-MM-DD (for session headers)
#   datetime - YYYY-MM-DD HH:MM (for detailed entries)
#   iso      - ISO 8601 format
#   session  - "YYYY-MM-DD Session" header format

set -euo pipefail

FORMAT="${1:-time}"

case "$FORMAT" in
    time)
        date +"%H:%M"
        ;;
    date)
        date +"%Y-%m-%d"
        ;;
    datetime)
        date +"%Y-%m-%d %H:%M"
        ;;
    iso)
        date -u +"%Y-%m-%dT%H:%M:%SZ"
        ;;
    session)
        echo "## Session: $(date +"%Y-%m-%d") $(date +"%A")"
        ;;
    milestone)
        # Output a milestone table row starter
        echo "| $(date +"%H:%M") |"
        ;;
    entry)
        # Output a progress entry header
        echo "### $(date +"%H:%M") -"
        ;;
    *)
        echo "Unknown format: $FORMAT"
        echo "Available: time, date, datetime, iso, session, milestone, entry"
        exit 1
        ;;
esac
