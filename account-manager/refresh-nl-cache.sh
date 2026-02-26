#!/bin/bash
# refresh-nl-cache.sh - Write nl usage data to cache
# Called by Chrome MCP sessions that can scrape claude.ai
#
# Usage:
#   echo '{"five_hour":...}' | refresh-nl-cache.sh
#   refresh-nl-cache.sh '{"five_hour":...}'

AM_DIR="$HOME/.claude/account-manager"
CACHE="$AM_DIR/account2-usage-cache.json"
MCP_RESULT="$AM_DIR/.nl-refresh-result"

if [[ -n "$1" ]]; then
    RAW="$1"
else
    RAW=$(cat)
fi

[[ -z "$RAW" ]] && { echo "Error: No data provided" >&2; exit 1; }

echo "$RAW" | python3 -c "
import json, sys
from datetime import datetime
d = json.loads(sys.stdin.read())
assert 'five_hour' in d, 'missing five_hour field'
d['_account'] = 2
d['_fetched_at'] = datetime.now().isoformat()
d['_source'] = 'chrome_mcp'
d.pop('_stale', None)
print(json.dumps(d, indent=2))
" > "${CACHE}.tmp" 2>/dev/null && mv "${CACHE}.tmp" "$CACHE" && cp "$CACHE" "$MCP_RESULT"

if [[ $? -eq 0 ]]; then
    echo "OK: nl cache updated at $(date '+%H:%M:%S')"
else
    echo "Error: Invalid JSON data" >&2
    exit 1
fi
