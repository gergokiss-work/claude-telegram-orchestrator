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

# Detect which account THIS specific claude process uses.
# CLAUDE_CONFIG_DIR env var is the source of truth — inherited from parent process.
# Account 2 (nl): CLAUDE_CONFIG_DIR=~/.claude-account2
# Account 1 (ns): CLAUDE_CONFIG_DIR unset or ~/.claude
if [[ "$CLAUDE_CONFIG_DIR" == *"account2"* ]]; then
    SESSION_ACCOUNT=2
else
    SESSION_ACCOUNT=1
fi

# Build compact account status from real API cache (updated every 5 min by monitor)
AM_DIR="$HOME/.claude/account-manager"

_acc_status() {
    local acc="$1"
    local cache="$AM_DIR/account${acc}-usage-cache.json"
    local tag
    [[ "$acc" == "1" ]] && tag="ns" || tag="nl"

    if [[ ! -f "$cache" ]]; then
        echo "${tag}:?"
        return
    fi

    # Check for error in cache (expired token, fetch failed, etc.)
    local cache_error
    cache_error=$(python3 -c "
import json
try:
    d = json.load(open('$cache'))
    print(d.get('error', ''))
except:
    print('parse_error')
" 2>/dev/null)

    if [[ -n "$cache_error" ]]; then
        case "$cache_error" in
            token_expired)  echo "${tag}:🔑❌" ;;
            token_revoked)  echo "${tag}:🔑🚫" ;;
            wrong_account)  echo "${tag}:👤❌WRONG" ;;
            fetch_failed)   echo "${tag}:⚠️" ;;
            network_error)  echo "${tag}:🌐❌" ;;
            no_token)       echo "${tag}:🔑?" ;;
            no_browser_data) echo "${tag}:📡?" ;;
            *)              echo "${tag}:?" ;;
        esac
        return
    fi

    # Single Python call: extract five_h, seven_d, reset_hhmm (local time), extra_util
    local stats
    stats=$(python3 -c "
import json, datetime
try:
    d = json.load(open('$cache'))
    five_h = int(d.get('five_hour', {}).get('utilization', 0) or 0)
    seven_d = int(d.get('seven_day', {}).get('utilization', 0) or 0)
    reset_raw = d.get('five_hour', {}).get('resets_at', '') or ''
    try:
        dt = datetime.datetime.fromisoformat(reset_raw.replace('Z','+00:00'))
        # Round up to next minute (API returns end-of-window, e.g. 17:59:59 → show 18:00)
        import math
        secs = dt.second + dt.microsecond / 1e6
        if secs >= 30:
            dt = dt + datetime.timedelta(seconds=60 - secs)
        reset_hhmm = dt.astimezone().strftime('%H:%M')
    except:
        reset_hhmm = '??:??'
    ex = d.get('extra_usage', {}) or {}
    if ex.get('is_enabled') and ex.get('utilization') is not None:
        extra = int(ex.get('utilization', 0) or 0)
    else:
        extra = -1
    print(f'{five_h} {seven_d} {reset_hhmm} {extra}')
except:
    print('0 0 ??:?? -1')
" 2>/dev/null || echo "0 0 ??:?? -1")

    local five_h seven_d reset_hhmm extra_util
    five_h=$(echo "$stats" | awk '{print $1}')
    seven_d=$(echo "$stats" | awk '{print $2}')
    reset_hhmm=$(echo "$stats" | awk '{print $3}')
    extra_util=$(echo "$stats" | awk '{print $4}')

    # Staleness indicator for browser-scraped data
    local stale_sfx=""
    local is_stale
    is_stale=$(python3 -c "
import json
try:
    d = json.load(open('$cache'))
    print('yes' if d.get('_stale') else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")
    [[ "$is_stale" == "yes" ]] && stale_sfx="📡"

    # Suffix: ⚡ = monthly burst cap exhausted
    local extra_sfx=""
    [[ "$extra_util" -ge 100 ]] && extra_sfx="⚡"

    # 7-day severity suffix
    local seven_d_sfx=""
    if [[ "$seven_d" -ge 85 ]]; then
        seven_d_sfx="🔴"
    elif [[ "$seven_d" -ge 70 ]]; then
        seven_d_sfx="⚠"
    fi

    # Format: tag:5h%/7d%@HH:MM  (blocked: tag:❌@HH:MM/7d%)
    if [[ "$five_h" -ge 100 ]]; then
        echo "${tag}:❌@${reset_hhmm}/${seven_d}%w${seven_d_sfx}${extra_sfx}${stale_sfx}"
    elif [[ "$five_h" -ge 80 ]]; then
        echo "${tag}:${five_h}%⚠/${seven_d}%w@${reset_hhmm}${seven_d_sfx}${extra_sfx}${stale_sfx}"
    else
        echo "${tag}:${five_h}%/${seven_d}%w@${reset_hhmm}${seven_d_sfx}${extra_sfx}${stale_sfx}"
    fi
}

ACC1_STATUS=$(_acc_status 1)
ACC2_STATUS=$(_acc_status 2)

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

# Build account usage suffix - mark active session's account with ▶
if [[ "$SESSION_ACCOUNT" == "2" ]]; then
    USAGE_SUFFIX=" | ${ACC1_STATUS} ▶${ACC2_STATUS}"
else
    USAGE_SUFFIX=" | ▶${ACC1_STATUS} ${ACC2_STATUS}"
fi

if [ "$PERCENT" -ge 75 ]; then
    echo "[$MODEL] 🔴 ${SHOW_PCT}% (${TOKENS_DISPLAY}) | ${REMAIN}% left${USAGE_SUFFIX}"
elif [ "$PERCENT" -ge "$THRESHOLD" ]; then
    echo "[$MODEL] 🟡 ${SHOW_PCT}% (${TOKENS_DISPLAY}) | ${REMAIN}% left${USAGE_SUFFIX} ⚠️"
else
    echo "[$MODEL] 🟢 ${SHOW_PCT}% (${TOKENS_DISPLAY}) | ${REMAIN}% left${USAGE_SUFFIX}"
fi
