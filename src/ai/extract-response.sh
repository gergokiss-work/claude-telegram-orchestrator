#!/bin/bash
# extract-response.sh - Use GPT to intelligently extract Claude's response from terminal noise
# Usage: extract-response.sh "raw terminal output"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../.."

[[ -f "$ROOT_DIR/.env.local" ]] && source "$ROOT_DIR/.env.local"
[[ -f "$ROOT_DIR/config.env" ]] && source "$ROOT_DIR/config.env"

LOG_FILE="$ROOT_DIR/logs/ai.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXTRACT: $*" >> "$LOG_FILE"
}

RAW_INPUT="$1"

if [[ -z "$RAW_INPUT" ]]; then
    RAW_INPUT=$(cat)
fi

if [[ -z "$RAW_INPUT" ]]; then
    exit 0
fi

# Quick cleanup of ANSI codes first
cleaned=$(echo "$RAW_INPUT" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')

if [[ -z "$OPENAI_API_KEY" ]]; then
    log "No API key, returning raw (truncated)"
    echo "$cleaned" | tail -20
    exit 0
fi

log "Extracting response from ${#cleaned} chars"

SYSTEM_PROMPT='You extract Claude'\''s response from terminal output for mobile Telegram.

The input is raw Claude Code CLI terminal output containing:
- Claude'\''s text responses (EXTRACT THESE)
- Tool calls like "⏺ Bash(...)", "⏺ Read(...)", "⏺ Update(...)" (SUMMARIZE briefly)
- Tool outputs like "⎿ ..." (IGNORE unless error)
- User prompts "❯" or ">" (IGNORE)
- Diff snippets, code fragments (SUMMARIZE if relevant)
- Box characters, ANSI noise (IGNORE)

OUTPUT FORMAT:
1. Start with Claude'\''s main response text (what Claude said/explained)
2. If actions were taken, add brief "Actions:" summary
3. If there are questions needing response, highlight them

RULES:
- Extract the SUBSTANCE, not the terminal chrome
- Keep responses concise for mobile
- Preserve important information
- If Claude asked a question, make it clear
- Max 1500 chars output'

escaped_input=$(echo "$cleaned" | jq -Rs .)
escaped_system=$(echo "$SYSTEM_PROMPT" | jq -Rs .)

response=$(curl -s "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"gpt-4o-mini\",
        \"max_tokens\": 800,
        \"temperature\": 0.2,
        \"messages\": [
            {\"role\": \"system\", \"content\": $escaped_system},
            {\"role\": \"user\", \"content\": $escaped_input}
        ]
    }")

extracted=$(echo "$response" | jq -r '.choices[0].message.content // empty')

if [[ -z "$extracted" ]]; then
    log "GPT failed, returning truncated raw"
    echo "$cleaned" | grep -vE '^⏺|^⎿|^❯|^>' | tail -20
else
    log "Extracted ${#extracted} chars"
    echo "$extracted"
fi
