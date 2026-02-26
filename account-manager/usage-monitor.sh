#!/bin/bash
# usage-monitor.sh - Background daemon: polls account usage every 5 min
# Sends TTS + Telegram alerts + injects warnings into agent sessions
# Start: nohup ~/.claude/account-manager/usage-monitor.sh &
# Stop:  kill $(cat /tmp/claude-usage-monitor.pid)

AM_DIR="$HOME/.claude/account-manager"
FETCH="$AM_DIR/fetch-usage.sh"
TG_SCRIPT="$HOME/.claude/telegram-orchestrator/send-summary.sh"
TTS_SCRIPT="$HOME/.claude/scripts/tts-write.sh"
INJECT="$HOME/.claude/telegram-orchestrator/inject-prompt.sh"

# Alert thresholds (%)
#
# 5-hour window (resets every ~5h):
#   WARN_5H=80  → TTS to user: "account at 80%, window filling up"
#   SWAP_5H=93  → agents get handoff request, sessions restart on other account
#               → 7% buffer left (~10-20 min) for agents to wrap up
#
# 7-day rolling window:
#   WARN_7D=70  → Telegram to user: passive heads-up, no agent action
#   CRIT_7D=85  → inject warning into all agents: "save progress, weekly budget at 85%"
#   SWAP_7D=95  → agents get handoff request, sessions restart on other account
#
WARN_5H=80    # 5h at 80%: TTS heads-up to user
SWAP_5H=93    # 5h at 93%: trigger handoff + auto-swap
WARN_7D=70    # 7d at 70%: Telegram to user (informational)
CRIT_7D=85    # 7d at 85%: inject "save progress" warning into agents
SWAP_7D=95    # 7d at 95%: trigger handoff + auto-swap

ALERT_DIR="/tmp/claude-usage-alerts"
PIDFILE="/tmp/claude-usage-monitor.pid"
LOGFILE="$AM_DIR/monitor.log"

mkdir -p "$ALERT_DIR"
echo $$ > "$PIDFILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

# Convert UTC ISO timestamp to local HH:MM
utc_to_local_hhmm() {
    local utc="$1"
    python3 -c "
import sys, datetime
s = '$utc'
try:
    dt = datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
    print(dt.astimezone().strftime('%H:%M'))
except Exception:
    print(s[11:16] if len(s) > 15 else '??:??')
" 2>/dev/null || echo "??:??"
}

# Read a numeric field from usage cache (returns 0 on failure)
get_field() {
    local cache="$1" field="$2"
    python3 -c "
import json
try:
    d = json.load(open('$cache'))
    print(int(d.get('$field', {}).get('utilization', 0) or 0))
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

get_reset() {
    local cache="$1" field="$2"
    python3 -c "
import json
try:
    d = json.load(open('$cache'))
    print(d.get('$field', {}).get('resets_at', '') or '')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

check_and_alert() {
    local acc="$1"
    local cache="$AM_DIR/account${acc}-usage-cache.json"

    [[ ! -f "$cache" ]] && return

    local five_h seven_d five_h_reset seven_d_reset acc_tag email extra_util
    five_h=$(get_field "$cache" "five_hour")
    seven_d=$(get_field "$cache" "seven_day")
    five_h_reset=$(get_reset "$cache" "five_hour")
    seven_d_reset=$(get_reset "$cache" "seven_day")
    extra_util=$(python3 -c "
import json
try:
    d = json.load(open('$cache'))
    ex = d.get('extra_usage', {}) or {}
    if ex.get('is_enabled') and ex.get('utilization') is not None:
        print(int(ex.get('utilization', 0) or 0))
    else:
        print(-1)
except: print(-1)
" 2>/dev/null || echo "-1")

    [[ "$acc" == "1" ]] && acc_tag="ns" && email="gergo.kiss@netlocksolutions.com"
    [[ "$acc" == "2" ]] && acc_tag="nl" && email="kiss.gergo@netlock.hu"

    # --- 5-hour limit alerts ---

    # Fully blocked (100%): notify user with reset time
    if [[ "$five_h" -ge 100 ]] && [[ ! -f "$ALERT_DIR/blocked_${acc}" ]]; then
        touch "$ALERT_DIR/blocked_${acc}"
        local reset_time
        reset_time=$(utc_to_local_hhmm "$five_h_reset")
        log "BLOCKED: Account $acc ($acc_tag) 5h limit hit. Resets at $reset_time"
        "$TTS_SCRIPT" "$acc_tag account blocked. Resets at $reset_time." &>/dev/null &
        "$TG_SCRIPT" --session "usage-monitor" "⛔ <b>$acc_tag Blocked</b>

🔴 <b>Account:</b> $email
⏰ <b>Resets at:</b> $reset_time
📊 <b>7-day usage:</b> ${seven_d}%
💡 <i>(Auto-swap should have already moved sessions at ${SWAP_5H}%)</i>" &>/dev/null &

    elif [[ "$five_h" -lt 90 ]]; then
        rm -f "$ALERT_DIR/blocked_${acc}" 2>/dev/null
    fi

    # Warning (80%): TTS heads-up to user — window filling up
    if [[ "$five_h" -ge "$WARN_5H" && "$five_h" -lt "$SWAP_5H" ]] && [[ ! -f "$ALERT_DIR/warn5h_${acc}" ]]; then
        touch "$ALERT_DIR/warn5h_${acc}"
        log "WARN: Account $acc ($acc_tag) 5h at ${five_h}% — heads-up"
        "$TTS_SCRIPT" "$acc_tag 5-hour window at ${five_h} percent." &>/dev/null &
    elif [[ "$five_h" -lt $(( WARN_5H - 10 )) ]]; then
        rm -f "$ALERT_DIR/warn5h_${acc}" 2>/dev/null
    fi

    # --- 7-day limit alerts ---

    if [[ "$seven_d" -ge "$CRIT_7D" ]] && [[ ! -f "$ALERT_DIR/crit7d_${acc}_$(( seven_d / 5 * 5 ))" ]]; then
        rm -f "$ALERT_DIR/crit7d_${acc}"_* 2>/dev/null
        touch "$ALERT_DIR/crit7d_${acc}_$(( seven_d / 5 * 5 ))"
        log "CRITICAL: Account $acc ($acc_tag) 7d at ${seven_d}% - injecting agent warnings"

        "$TG_SCRIPT" --session "usage-monitor" "🚨 <b>$acc_tag Weekly Limit Critical: ${seven_d}%</b>

📊 7-day utilization is at ${seven_d}%
🔴 Threshold: ${CRIT_7D}% (critical)
💡 <i>All agents warned to save progress. Consider account switch.</i>" &>/dev/null &

        "$TTS_SCRIPT" "$acc_tag weekly limit at ${seven_d} percent. Agents warned to save progress." &>/dev/null &

        # Inject warning into all active Claude tmux sessions
        while IFS= read -r sess; do
            [[ -z "$sess" ]] && continue
            "$INJECT" "$sess" "⚠️ USAGE ALERT: $acc_tag account 7-day limit is at ${seven_d}%. Please save your progress and prepare for a possible account switch soon." &>/dev/null &
        done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^claude-|^nl-|^ns-')

    elif [[ "$seven_d" -ge "$WARN_7D" && "$seven_d" -lt "$CRIT_7D" ]] && [[ ! -f "$ALERT_DIR/warn7d_${acc}_$(( seven_d / 5 * 5 ))" ]]; then
        rm -f "$ALERT_DIR/warn7d_${acc}"_* 2>/dev/null
        touch "$ALERT_DIR/warn7d_${acc}_$(( seven_d / 5 * 5 ))"
        local reset_date
        reset_date="${seven_d_reset:0:10}"
        log "WARN: Account $acc ($acc_tag) 7d at ${seven_d}%, resets $reset_date"
        "$TG_SCRIPT" --session "usage-monitor" "⚠️ <b>$acc_tag Weekly Usage: ${seven_d}%</b>

📊 7-day utilization approaching limit
⏱ Resets: $reset_date" &>/dev/null &
    fi

    # --- Monthly extra_usage alerts ---
    if [[ "$extra_util" -ge 100 ]] && [[ ! -f "$ALERT_DIR/extra_exhausted_${acc}" ]]; then
        touch "$ALERT_DIR/extra_exhausted_${acc}"
        log "INFO: Account $acc ($acc_tag) extra_usage exhausted (monthly burst cap hit)"
        "$TTS_SCRIPT" "$acc_tag monthly burst capacity exhausted. No overflow credits until next billing cycle." &>/dev/null &
        "$TG_SCRIPT" --session "usage-monitor" "⚡ <b>$acc_tag Monthly Burst Exhausted</b>

💳 Extra usage credits used up for this billing cycle
🔴 <b>Account:</b> $email
💡 <i>Base subscription still works. No burst capacity until monthly reset.</i>" &>/dev/null &
    elif [[ "$extra_util" -ge 0 && "$extra_util" -lt 90 ]]; then
        # Monthly reset happened — clear the flag
        rm -f "$ALERT_DIR/extra_exhausted_${acc}" 2>/dev/null
    fi

    # --- Auto-swap triggers ---
    # 5h: at SWAP_5H% trigger handoff+swap (fires before 100% hard block)
    if [[ "$five_h" -ge "$SWAP_5H" && "$five_h" -lt 100 ]] && [[ ! -f "$ALERT_DIR/swap5h_${acc}" ]]; then
        touch "$ALERT_DIR/swap5h_${acc}"
        log "SWAP TRIGGER: Account $acc ($acc_tag) 5h at ${five_h}% — launching auto-swap"
        ( "$AM_DIR/auto-swap.sh" --from-account "$acc" --reason "5h_${five_h}%" ) >> "$AM_DIR/auto-swap.log" 2>&1 &
    elif [[ "$five_h" -lt $(( SWAP_5H - 10 )) ]]; then
        rm -f "$ALERT_DIR/swap5h_${acc}" 2>/dev/null
    fi

    # 7d: at SWAP_7D% trigger handoff+swap (weekly near-limit)
    if [[ "$seven_d" -ge "$SWAP_7D" ]] && [[ ! -f "$ALERT_DIR/swap7d_${acc}" ]]; then
        touch "$ALERT_DIR/swap7d_${acc}"
        log "SWAP TRIGGER: Account $acc ($acc_tag) 7d at ${seven_d}% — launching auto-swap"
        ( "$AM_DIR/auto-swap.sh" --from-account "$acc" --reason "7d_${seven_d}%" ) >> "$AM_DIR/auto-swap.log" 2>&1 &
    elif [[ "$seven_d" -lt $(( SWAP_7D - 10 )) ]]; then
        rm -f "$ALERT_DIR/swap7d_${acc}" 2>/dev/null
    fi
}

log "Usage monitor started (PID $$, interval: 5min)"
log "Thresholds: 5h warn=${WARN_5H}% swap=${SWAP_5H}% | 7d warn=${WARN_7D}% crit=${CRIT_7D}% swap=${SWAP_7D}%"

# Initial fetch immediately on start
log "Initial fetch..."
"$FETCH" 1 > /dev/null 2>&1 && log "Account 1 fetched OK" || log "Account 1 fetch failed"
"$FETCH" 2 > /dev/null 2>&1 && log "Account 2 fetched OK" || log "Account 2 fetch failed"
check_and_alert 1
check_and_alert 2

while true; do
    sleep 300
    log "Polling usage..."
    "$FETCH" 1 > /dev/null 2>&1 && log "Account 1 OK" || log "Account 1 failed"
    "$FETCH" 2 > /dev/null 2>&1 && log "Account 2 OK" || log "Account 2 failed"
    check_and_alert 1
    check_and_alert 2
done
