#!/bin/bash
# fetch-nl-browser.sh - Fetch nl (account 2) usage via Chrome browser scrape
#
# The OAuth API always returns ns-scoped data for nl tokens (multi-org bug).
# This script fetches correct nl usage from claude.ai browser API instead.
#
# Methods tried in order:
#   1. osascript → Chrome JS (requires "Allow JavaScript from Apple Events")
#   2. Existing cache if fresh enough (< 15 min)
#   3. Mark cache as stale but preserve data
#
# Output: JSON saved to account2-usage-cache.json, printed to stdout

AM_DIR="$HOME/.claude/account-manager"
CACHE="$AM_DIR/account2-usage-cache.json"
NL_ORG="cc1c9618-cd9a-470b-aab9-8e9976a1dadd"
USAGE_URL="/api/organizations/$NL_ORG/usage"
MAX_CACHE_AGE=900  # 15 minutes in seconds
OSASCRIPT_TIMEOUT=10  # seconds

log() {
    echo "[$(date '+%H:%M:%S')] fetch-nl-browser: $*" >> "$AM_DIR/monitor.log"
}

write_cache() {
    echo "$1" > "$CACHE"
    cat "$CACHE"
}

# Check if existing cache is fresh enough (returns age in seconds)
cache_age() {
    [[ ! -f "$CACHE" ]] && { echo "999999"; return; }
    python3 -c "
import json
from datetime import datetime
try:
    d = json.load(open('$CACHE'))
    dt = datetime.fromisoformat(d.get('_fetched_at', ''))
    print(int((datetime.now() - dt).total_seconds()))
except:
    print(999999)
" 2>/dev/null || echo "999999"
}

# Check if existing cache has an error
cache_has_error() {
    python3 -c "
import json
try:
    d = json.load(open('$CACHE'))
    print('yes' if 'error' in d else 'no')
except:
    print('yes')
" 2>/dev/null || echo "yes"
}

# Method 1: osascript Chrome JS (with timeout to prevent hangs)
try_osascript() {
    local tmpfile
    tmpfile=$(mktemp /tmp/nl-osascript-XXXXXX.json)
    trap "rm -f '$tmpfile'" RETURN

    # Run osascript with timeout to prevent hang if Chrome is frozen
    timeout "$OSASCRIPT_TIMEOUT" osascript -e "
tell application \"Google Chrome\"
    if not running then return \"CHROME_NOT_RUNNING\"
    repeat with w in every window
        repeat with t in every tab of w
            if URL of t contains \"claude.ai\" then
                set jsResult to execute t javascript \"
                    (function() {
                        try {
                            var xhr = new XMLHttpRequest();
                            xhr.open('GET', '$USAGE_URL', false);
                            xhr.timeout = 8000;
                            xhr.send();
                            if (xhr.status === 200) {
                                return xhr.responseText;
                            } else {
                                return '{\\\"error\\\":\\\"http_' + xhr.status + '\\\"}';
                            }
                        } catch(e) {
                            return '{\\\"error\\\":\\\"xhr_failed\\\"}';
                        }
                    })()
                \"
                return jsResult
            end if
        end repeat
    end repeat
    return \"NO_CLAUDE_TAB\"
end tell
" > "$tmpfile" 2>/dev/null

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        return 1
    fi

    local raw
    raw=$(cat "$tmpfile")
    [[ -z "$raw" || "$raw" == "NO_CLAUDE_TAB" || "$raw" == "CHROME_NOT_RUNNING" ]] && return 1

    # Validate JSON and add metadata (use stdin to avoid shell escaping issues)
    echo "$raw" | python3 -c "
import json, sys
from datetime import datetime
raw = sys.stdin.read().strip()
d = json.loads(raw)
if 'error' in d:
    sys.exit(1)
assert 'five_hour' in d, 'missing five_hour'
d['_account'] = 2
d['_fetched_at'] = datetime.now().isoformat()
d['_source'] = 'browser_osascript'
print(json.dumps(d, indent=2))
" 2>/dev/null
}

# --- Main ---

# Try osascript first (only if Chrome is running to avoid launching it)
if pgrep -q "Google Chrome"; then
    RESULT=$(try_osascript)
    if [[ $? -eq 0 ]] && [[ -n "$RESULT" ]]; then
        log "osascript OK"
        write_cache "$RESULT"
        exit 0
    fi
    log "osascript failed"
else
    log "Chrome not running, skipping osascript"
fi

# Check if MCP result file was recently updated (by a Chrome MCP Claude session)
MCP_RESULT="$AM_DIR/.nl-refresh-result"
if [[ -f "$MCP_RESULT" ]]; then
    MCP_AGE=$(python3 -c "
import os, time
print(int(time.time() - os.path.getmtime('$MCP_RESULT')))
" 2>/dev/null || echo "999999")
    if [[ "$MCP_AGE" -lt "$MAX_CACHE_AGE" ]]; then
        # MCP result is fresh - use it
        cp "$MCP_RESULT" "$CACHE"
        log "Using MCP result (age: ${MCP_AGE}s)"
        cat "$CACHE"
        exit 0
    fi
fi

# Check if existing cache is still fresh enough
AGE=$(cache_age)
HAS_ERROR=$(cache_has_error)
if [[ "$AGE" -lt "$MAX_CACHE_AGE" ]] && [[ "$HAS_ERROR" == "no" ]]; then
    log "Using cached data (age: ${AGE}s)"
    cat "$CACHE"
    exit 0
fi

# Cache is stale but has valid data - preserve it with staleness flag
if [[ "$HAS_ERROR" == "no" ]] && [[ -f "$CACHE" ]]; then
    python3 -c "
import json
from datetime import datetime
d = json.load(open('$CACHE'))
d['_stale'] = True
d['_cache_age_seconds'] = $AGE
d['_last_refresh_attempt'] = datetime.now().isoformat()
print(json.dumps(d, indent=2))
" > "${CACHE}.tmp" 2>/dev/null && mv "${CACHE}.tmp" "$CACHE"
    log "Cache stale (age: ${AGE}s), preserved with _stale flag"
    cat "$CACHE"
    exit 0
fi

# No usable cache at all
log "No usable cache"
write_cache "{\"error\":\"no_browser_data\",\"account\":2,\"_fetched_at\":\"$(date -Iseconds)\",\"_hint\":\"Enable Chrome AppleScript JS or refresh via Chrome MCP\"}"
exit 1
