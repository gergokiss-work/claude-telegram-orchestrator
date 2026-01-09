#!/bin/bash
# format-output.sh - Format Claude output for Telegram using GPT-4o-mini
# Usage: format-output.sh < raw_output
# Or: format-output.sh "raw output text"

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../.."

# Source config
[[ -f "$ROOT_DIR/.env.local" ]] && source "$ROOT_DIR/.env.local"
[[ -f "$ROOT_DIR/config.env" ]] && source "$ROOT_DIR/config.env"

LOG_FILE="$ROOT_DIR/logs/ai.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FORMAT: $*" >> "$LOG_FILE"
}

# Get input from argument or stdin
if [[ -n "$1" ]]; then
    RAW_OUTPUT="$1"
else
    RAW_OUTPUT=$(cat)
fi

# Skip empty input
if [[ -z "$RAW_OUTPUT" ]]; then
    exit 0
fi

# Step 1: Basic cleanup (always do this, no AI needed)
cleaned=$(echo "$RAW_OUTPUT" | \
    sed 's/\x1b\[[0-9;]*m//g' | \
    grep -vE '^\s*$' | \
    grep -vE '^(╭|╰|│|─|├|┤|┬|┴|┼)' | \
    grep -vE '^⏺ (Bash|Read|Edit|Write|Grep|Glob|Task|Update|WebFetch|WebSearch|TodoWrite|NotebookEdit)' | \
    grep -vE '^\s*(Running|Completed|Output|Marinating|Thinking)' | \
    grep -vE 'tokens remaining|bypass permissions|esc to interrupt|shift\+tab' | \
    grep -vE '^\s*>\s*$' | \
    cat -s)

char_count=${#cleaned}
log "Input: $char_count chars after basic cleanup"

# Step 2: If short enough, just return cleaned version
THRESHOLD="${FORMAT_THRESHOLD:-1500}"

if [[ $char_count -le $THRESHOLD ]]; then
    log "Under threshold, returning cleaned output"
    echo "$cleaned"
    exit 0
fi

# Step 3: If too long, use GPT to summarize
if [[ -z "$OPENAI_API_KEY" ]]; then
    log "WARN: OPENAI_API_KEY not set, truncating instead of summarizing"
    echo "${cleaned:0:1500}..."
    exit 0
fi

log "Over threshold ($char_count > $THRESHOLD), calling GPT for summary"

SYSTEM_PROMPT="You format Claude Code CLI output for mobile Telegram.

Rules:
1. Extract the ESSENTIAL information only
2. What was done? Any errors? Final status?
3. Maximum 800 characters
4. Use clean formatting (no markdown headers, simple bullets ok)
5. Preserve short code snippets if crucial
6. Be direct and concise - this is for mobile
7. If there are errors, highlight them
8. Never add information that wasn't in the original"

# Escape for JSON
escaped_input=$(echo "$cleaned" | jq -Rs .)
escaped_system=$(echo "$SYSTEM_PROMPT" | jq -Rs .)

response=$(curl -s "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"gpt-4o-mini\",
        \"max_tokens\": 500,
        \"temperature\": 0.3,
        \"messages\": [
            {\"role\": \"system\", \"content\": $escaped_system},
            {\"role\": \"user\", \"content\": $escaped_input}
        ]
    }")

formatted=$(echo "$response" | jq -r '.choices[0].message.content // empty')

if [[ -z "$formatted" ]]; then
    log "WARN: GPT returned empty, using truncated original"
    echo "${cleaned:0:1500}..."
else
    log "GPT summary: ${#formatted} chars"
    echo "$formatted"
fi
