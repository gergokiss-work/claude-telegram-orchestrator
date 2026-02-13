#!/bin/bash
input=$(cat)

# Log for debugging
echo "$input" > /tmp/statusline-last-input.json

MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null)
CONTEXT_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000' 2>/dev/null)

# Calculate current context usage
# Use current_usage tokens + cache tokens as approximation
INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null)
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0' 2>/dev/null)
CACHE_CREATE=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null)
CACHE_READ=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null)

# Total tokens in context (cache_read counts but at reduced cost)
TOTAL_TOKENS=$((INPUT_TOKENS + OUTPUT_TOKENS + CACHE_CREATE + CACHE_READ))

# Calculate percentage
if [ "$CONTEXT_SIZE" -gt 0 ] 2>/dev/null; then
    PERCENT=$((TOTAL_TOKENS * 100 / CONTEXT_SIZE))
    REMAIN=$((100 - PERCENT))
else
    PERCENT=0
    REMAIN=100
fi

# Cap at 100
[ "$PERCENT" -gt 100 ] && PERCENT=100
[ "$REMAIN" -lt 0 ] && REMAIN=0

# Format token count for display (K format)
if [ "$TOTAL_TOKENS" -ge 1000 ]; then
    TOKENS_DISPLAY="$((TOTAL_TOKENS / 1000))k"
else
    TOKENS_DISPLAY="$TOTAL_TOKENS"
fi

# Dynamic threshold: For large context windows (1M+), use absolute token threshold
# instead of percentage-based, to prevent sessions from running too long
ABSOLUTE_TOKEN_THRESHOLD=150000  # Respawn at ~150K tokens regardless of window size
if [ "$CONTEXT_SIZE" -gt 500000 ] 2>/dev/null; then
    # Large context window (e.g., Opus 4.6 with 1M) - use absolute threshold
    if [ "$TOTAL_TOKENS" -gt 0 ]; then
        PERCENT=$((TOTAL_TOKENS * 100 / ABSOLUTE_TOKEN_THRESHOLD))
        # Cap effective percentage for display (still show real % of window)
        DISPLAY_PERCENT=$((TOTAL_TOKENS * 100 / CONTEXT_SIZE))
        REMAIN=$((100 - DISPLAY_PERCENT))
        [ "$REMAIN" -lt 0 ] && REMAIN=0
    fi
fi

# Session and account detection
SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "unknown")

# Detect account from session name or CLAUDE_CONFIG_DIR
if [[ "$CLAUDE_CONFIG_DIR" == *"account2"* ]] || [[ "$SESSION" == *"-acc2"* ]] || [[ "$SESSION" == nl-* ]]; then
    ACTIVE_ACCOUNT=2
else
    ACTIVE_ACCOUNT=1
fi

# Log token usage async (non-blocking, runs in background)
TRACKER="$HOME/.claude/account-manager/usage-tracker.sh"
if [[ -x "$TRACKER" ]] && [[ "$TOTAL_TOKENS" -gt 0 ]]; then
    ( "$TRACKER" log "$ACTIVE_ACCOUNT" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$CACHE_CREATE" "$CACHE_READ" ) &>/dev/null &
fi

# Get weekly usage for display (cached: only refresh every 60 seconds)
WEEKLY_CACHE="/tmp/statusline-weekly-${ACTIVE_ACCOUNT}.cache"
WEEKLY_PCT=""
if [[ -x "$TRACKER" ]]; then
    local_now=$(date +%s)
    cache_age=999
    if [[ -f "$WEEKLY_CACHE" ]]; then
        cache_mtime=$(stat -f %m "$WEEKLY_CACHE" 2>/dev/null || echo "0")
        cache_age=$((local_now - cache_mtime))
    fi
    if [[ "$cache_age" -ge 60 ]]; then
        WEEKLY_PCT=$("$TRACKER" weekly-percent "$ACTIVE_ACCOUNT" 2>/dev/null || echo "")
        [[ -n "$WEEKLY_PCT" ]] && echo "$WEEKLY_PCT" > "$WEEKLY_CACHE"
    else
        WEEKLY_PCT=$(cat "$WEEKLY_CACHE" 2>/dev/null || echo "")
    fi
fi

# Format account tag
if [[ "$ACTIVE_ACCOUNT" == "2" ]]; then
    ACC_TAG="nl"
else
    ACC_TAG="ns"
fi

# Color coding and handoff trigger
HANDOFF_DIR="$HOME/.claude/handoffs"
HANDOFF_FLAG="$HANDOFF_DIR/.triggered-$SESSION"
mkdir -p "$HANDOFF_DIR" 2>/dev/null

# Read threshold and exclusions from config (default 60)
THRESHOLD=$(jq -r '.threshold_percent // 60' "$HOME/.claude/handoff-config.json" 2>/dev/null || echo "60")
# NOTE: jq `//` treats boolean false as falsy, so we must use explicit check
CONTEXT_WATCH=$(jq -r 'if .context_watch == false then "false" else "true" end' "$HOME/.claude/handoff-config.json" 2>/dev/null || echo "true")
IS_EXCLUDED=$(jq -r --arg s "$SESSION" '.excluded_sessions // [] | if index($s) then "true" else "false" end' "$HOME/.claude/handoff-config.json" 2>/dev/null || echo "false")

if [ "$CONTEXT_WATCH" != "false" ] && [ "$PERCENT" -ge "$THRESHOLD" ] && [ ! -f "$HANDOFF_FLAG" ] && [ "$SESSION" != "unknown" ] && [ "$IS_EXCLUDED" != "true" ]; then
    touch "$HANDOFF_FLAG"
    ( ~/.claude/scripts/trigger-handoff.sh "$SESSION" "$PERCENT" ) &>/dev/null &
fi

# For display: use scaled PERCENT (against cap) so color matches the number
# When in large-window mode, show both effective % and token count
SHOW_PCT="$PERCENT"
[ "$SHOW_PCT" -gt 100 ] && SHOW_PCT=100

# Build weekly suffix
WEEKLY_SUFFIX=""
if [[ -n "$WEEKLY_PCT" ]]; then
    WEEKLY_SUFFIX=" | ${SESSION}@${ACC_TAG} ${WEEKLY_PCT}%w"
fi

if [ "$PERCENT" -ge 75 ]; then
    echo "[$MODEL] 🔴 ${SHOW_PCT}% (${TOKENS_DISPLAY}) | ${REMAIN}% left${WEEKLY_SUFFIX}"
elif [ "$PERCENT" -ge "$THRESHOLD" ]; then
    echo "[$MODEL] 🟡 ${SHOW_PCT}% (${TOKENS_DISPLAY}) | ${REMAIN}% left${WEEKLY_SUFFIX} ⚠️"
else
    echo "[$MODEL] 🟢 ${SHOW_PCT}% (${TOKENS_DISPLAY}) | ${REMAIN}% left${WEEKLY_SUFFIX}"
fi
