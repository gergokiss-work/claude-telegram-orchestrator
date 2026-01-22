#!/bin/bash
# Check current context usage from statusline cache
# Usage: ~/.claude/scripts/check-context.sh
# Returns: percentage and recommendation

CACHE_FILE="/tmp/statusline-last-input.json"
THRESHOLD=50

if [ ! -f "$CACHE_FILE" ]; then
    echo "Context: unknown (no cache)"
    exit 1
fi

# Read cached values
INPUT_TOKENS=$(jq -r '.context_window.current_usage.input_tokens // 0' "$CACHE_FILE" 2>/dev/null)
OUTPUT_TOKENS=$(jq -r '.context_window.current_usage.output_tokens // 0' "$CACHE_FILE" 2>/dev/null)
CACHE_CREATE=$(jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' "$CACHE_FILE" 2>/dev/null)
CACHE_READ=$(jq -r '.context_window.current_usage.cache_read_input_tokens // 0' "$CACHE_FILE" 2>/dev/null)
CONTEXT_SIZE=$(jq -r '.context_window.context_window_size // 200000' "$CACHE_FILE" 2>/dev/null)

TOTAL=$((INPUT_TOKENS + OUTPUT_TOKENS + CACHE_CREATE + CACHE_READ))
PERCENT=$((TOTAL * 100 / CONTEXT_SIZE))
REMAIN=$((100 - PERCENT))

# Output based on mode
if [ "$1" = "--json" ]; then
    echo "{\"percent\": $PERCENT, \"remaining\": $REMAIN, \"threshold\": $THRESHOLD, \"should_handoff\": $([ $PERCENT -ge $THRESHOLD ] && echo true || echo false)}"
elif [ "$1" = "--percent" ]; then
    echo "$PERCENT"
elif [ "$1" = "--check" ]; then
    # Silent check - returns 0 if OK to continue, 1 if should handoff
    [ $PERCENT -lt $THRESHOLD ] && exit 0 || exit 1
else
    # Human readable
    if [ $PERCENT -ge 65 ]; then
        echo "Context: ${PERCENT}% - CRITICAL - Hand off NOW"
    elif [ $PERCENT -ge $THRESHOLD ]; then
        echo "Context: ${PERCENT}% - At threshold - Complete current task then hand off"
    elif [ $PERCENT -ge 40 ]; then
        echo "Context: ${PERCENT}% - Approaching threshold - Consider task size before starting"
    else
        echo "Context: ${PERCENT}% - OK to continue"
    fi
fi
