#!/bin/bash
# find-session.sh - Find a Claude session by natural language query
# Usage: find-session.sh "auth bug fix"
#
# Searches ~/.claude/history.jsonl for sessions matching the query
# Uses Claude API to semantically match the best session
# Returns the session ID on success, empty on failure

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source configs
[[ -f "$SCRIPT_DIR/.env.local" ]] && source "$SCRIPT_DIR/.env.local"
[[ -f "$SCRIPT_DIR/config.env" ]] && source "$SCRIPT_DIR/config.env"

QUERY="$1"
MAX_SESSIONS=15  # How many recent sessions to consider

if [[ -z "$QUERY" ]]; then
    echo "Usage: find-session.sh \"your search query\"" >&2
    exit 1
fi

HISTORY_FILE="$HOME/.claude/history.jsonl"

if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "ERROR: No history file found at $HISTORY_FILE" >&2
    exit 1
fi

LOG_FILE="$SCRIPT_DIR/logs/find-session.log"
mkdir -p "$SCRIPT_DIR/logs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FIND: $*" >> "$LOG_FILE"
}

log "Searching for: $QUERY"

# Extract sessions and group messages by session ID
# Create a temp file with session summaries
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Get unique session IDs with their messages (most recent first based on file order)
# Group by sessionId and concatenate display messages
cat "$HISTORY_FILE" | jq -r '
    select(.sessionId) | select(.display) |
    "\(.sessionId)||||\(.project // "unknown")||||\(.display | .[0:150])"
' 2>/dev/null | tail -300 | while IFS= read -r line; do
    session_id=$(echo "$line" | cut -d'|' -f1)
    project=$(echo "$line" | cut -d'|' -f5)
    display=$(echo "$line" | cut -d'|' -f9-)

    # Write to temp file: session_id \t project \t message
    echo -e "${session_id}\t${project}\t${display}"
done > "$TEMP_FILE"

if [[ ! -s "$TEMP_FILE" ]]; then
    log "No sessions found in history"
    echo ""
    exit 0
fi

# Get unique sessions with combined messages
SESSIONS_FILE=$(mktemp)
trap "rm -f $TEMP_FILE $SESSIONS_FILE" EXIT

# Aggregate messages per session (take first occurrence of each session = most recent)
awk -F'\t' '!seen[$1]++ {print}' "$TEMP_FILE" | head -$MAX_SESSIONS > "$SESSIONS_FILE"

session_count=$(wc -l < "$SESSIONS_FILE" | tr -d ' ')
log "Found $session_count unique sessions to analyze"

if [[ "$session_count" -eq 0 ]]; then
    log "No sessions to analyze"
    echo ""
    exit 0
fi

# Build session list for Claude
sessions_list=""
while IFS=$'\t' read -r session_id project display; do
    sessions_list+="SESSION: $session_id
PROJECT: $project
CONTENT: $display
---
"
done < "$SESSIONS_FILE"

# Check if we have Claude API access
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    # Fallback: simple keyword matching
    log "No ANTHROPIC_API_KEY, using keyword search"

    best_match=""
    while IFS=$'\t' read -r session_id project display; do
        # Check if query words appear in content (case insensitive)
        match=true
        for word in $QUERY; do
            if ! echo "$display $project" | grep -qi "$word"; then
                match=false
                break
            fi
        done
        if $match; then
            best_match="$session_id"
            break
        fi
    done < "$SESSIONS_FILE"

    # If exact match failed, try partial (any word)
    if [[ -z "$best_match" ]]; then
        while IFS=$'\t' read -r session_id project display; do
            for word in $QUERY; do
                if echo "$display $project" | grep -qi "$word"; then
                    best_match="$session_id"
                    break 2
                fi
            done
        done < "$SESSIONS_FILE"
    fi

    if [[ -n "$best_match" ]]; then
        log "Keyword match found: $best_match"
        echo "$best_match"
    else
        log "No keyword match found"
        echo ""
    fi
    exit 0
fi

# Call Claude API for semantic matching
log "Calling Claude API for semantic match..."

prompt="Find the session that best matches this query: \"$QUERY\"

Here are the available sessions:

$sessions_list

Reply with ONLY the session ID (the UUID) that best matches the query.
If no session matches well, reply with NONE.
Do not include any explanation, just the session ID or NONE."

response=$(curl -s "https://api.anthropic.com/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "{
        \"model\": \"claude-haiku-4-5-20251001\",
        \"max_tokens\": 100,
        \"messages\": [{
            \"role\": \"user\",
            \"content\": $(echo "$prompt" | jq -Rs .)
        }]
    }" 2>/dev/null)

# Extract the session ID from response
result=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null | tr -d ' \n\r')

if [[ "$result" == "NONE" || -z "$result" ]]; then
    log "No matching session found by Claude"
    echo ""
    exit 0
fi

# Validate it looks like a UUID
if [[ "$result" =~ ^[a-f0-9-]{36}$ ]]; then
    log "Found matching session: $result"
    echo "$result"
else
    log "Invalid session ID returned: $result"
    # Try to extract UUID from response if Claude added extra text
    extracted=$(echo "$result" | grep -oE '[a-f0-9-]{36}' | head -1)
    if [[ -n "$extracted" ]]; then
        log "Extracted session ID: $extracted"
        echo "$extracted"
    else
        echo ""
    fi
fi
