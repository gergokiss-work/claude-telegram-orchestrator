#!/bin/bash
# smart-rotate.sh - Intelligent account rotation based on weekly usage
# Usage:
#   smart-rotate.sh recommend             # Recommend account for next session
#   smart-rotate.sh recommend <session_num>  # Recommend with session number hint
#   smart-rotate.sh status                # Show both accounts' usage status
#   smart-rotate.sh check-alerts          # Check for high-usage alerts (for watchdog)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACKER="$SCRIPT_DIR/usage-tracker.sh"
NOTIFY="$HOME/.claude/telegram-orchestrator/notify.sh"

# Thresholds
BALANCE_THRESHOLD=70    # Start preferring lower-usage account
WARNING_THRESHOLD=80    # Warn user via Telegram
FORCE_THRESHOLD=90      # Force all sessions to other account
CRITICAL_THRESHOLD=95   # Reduce sessions, strong warning

# Get weekly percent for an account (0-100)
get_usage() {
    local account="$1"
    "$TRACKER" weekly-percent "$account" 2>/dev/null || echo "0"
}

# Recommend which account to use for next session
cmd_recommend() {
    local session_num="${1:-}"
    local acc1_usage
    acc1_usage=$(get_usage 1)
    local acc2_usage
    acc2_usage=$(get_usage 2)

    # Decision matrix (from audit section 6.5)

    # Critical: both above critical threshold
    if [[ "$acc1_usage" -ge "$CRITICAL_THRESHOLD" ]] && [[ "$acc2_usage" -ge "$CRITICAL_THRESHOLD" ]]; then
        echo "acc1"  # Default, but caller should reduce sessions
        echo "CRITICAL" >&2
        return 2  # Special exit code: critical
    fi

    # Force: one account above force threshold
    if [[ "$acc1_usage" -ge "$FORCE_THRESHOLD" ]] && [[ "$acc2_usage" -lt "$FORCE_THRESHOLD" ]]; then
        echo "acc2"
        return 0
    fi
    if [[ "$acc2_usage" -ge "$FORCE_THRESHOLD" ]] && [[ "$acc1_usage" -lt "$FORCE_THRESHOLD" ]]; then
        echo "acc1"
        return 0
    fi

    # Balance: one account above balance threshold
    if [[ "$acc1_usage" -ge "$BALANCE_THRESHOLD" ]] && [[ "$acc2_usage" -lt "$BALANCE_THRESHOLD" ]]; then
        echo "acc2"
        return 0
    fi
    if [[ "$acc2_usage" -ge "$BALANCE_THRESHOLD" ]] && [[ "$acc1_usage" -lt "$BALANCE_THRESHOLD" ]]; then
        echo "acc1"
        return 0
    fi

    # Both stressed (above balance but below force): use less-used
    if [[ "$acc1_usage" -ge "$BALANCE_THRESHOLD" ]] && [[ "$acc2_usage" -ge "$BALANCE_THRESHOLD" ]]; then
        if [[ "$acc1_usage" -le "$acc2_usage" ]]; then
            echo "acc1"
        else
            echo "acc2"
        fi
        return 0
    fi

    # Both healthy: balance by usage, with slight preference for lower-usage account
    if [[ "$acc1_usage" -le "$acc2_usage" ]]; then
        echo "acc1"
    else
        echo "acc2"
    fi
    return 0
}

# Show status of both accounts
cmd_status() {
    local acc1_usage
    acc1_usage=$(get_usage 1)
    local acc2_usage
    acc2_usage=$(get_usage 2)
    local both_json
    both_json=$("$TRACKER" both-weekly)

    local acc1_tokens
    acc1_tokens=$(echo "$both_json" | jq -r '.acc1.tokens')
    local acc2_tokens
    acc2_tokens=$(echo "$both_json" | jq -r '.acc2.tokens')

    local acc1_icon acc2_icon
    if [[ "$acc1_usage" -ge "$FORCE_THRESHOLD" ]]; then
        acc1_icon="🔴"
    elif [[ "$acc1_usage" -ge "$WARNING_THRESHOLD" ]]; then
        acc1_icon="🟡"
    else
        acc1_icon="🟢"
    fi

    if [[ "$acc2_usage" -ge "$FORCE_THRESHOLD" ]]; then
        acc2_icon="🔴"
    elif [[ "$acc2_usage" -ge "$WARNING_THRESHOLD" ]]; then
        acc2_icon="🟡"
    else
        acc2_icon="🟢"
    fi

    local active
    active=$(cat "$SCRIPT_DIR/active-account" 2>/dev/null || echo "1")
    local recommended
    recommended=$(cmd_recommend 2>/dev/null)

    echo "📊 Account Usage Status"
    echo "━━━━━━━━━━━━━━━━━━━━━"
    echo "${acc1_icon} Account 1 (ns): ${acc1_usage}% weekly (${acc1_tokens} tokens)"
    echo "${acc2_icon} Account 2 (nl): ${acc2_usage}% weekly (${acc2_tokens} tokens)"
    echo "━━━━━━━━━━━━━━━━━━━━━"
    echo "Active: Account ${active} | Recommended: ${recommended}"
}

# Check alerts and notify if needed (called by watchdog)
cmd_check_alerts() {
    local acc1_usage
    acc1_usage=$(get_usage 1)
    local acc2_usage
    acc2_usage=$(get_usage 2)

    local alert_sent=false
    local alert_file="$SCRIPT_DIR/usage/.last-alert"

    # Don't spam: only alert once per hour
    if [[ -f "$alert_file" ]]; then
        local last_alert
        last_alert=$(cat "$alert_file")
        local now
        now=$(date +%s)
        local diff=$((now - last_alert))
        if [[ "$diff" -lt 3600 ]]; then
            return 0
        fi
    fi

    # Critical: both accounts near limit
    if [[ "$acc1_usage" -ge "$CRITICAL_THRESHOLD" ]] && [[ "$acc2_usage" -ge "$CRITICAL_THRESHOLD" ]]; then
        if [[ -f "$NOTIFY" ]]; then
            "$NOTIFY" "warning" "system" "🚨 CRITICAL: Both accounts near weekly limit!
Account 1: ${acc1_usage}%
Account 2: ${acc2_usage}%
Consider reducing active sessions."
        fi
        date +%s > "$alert_file"
        alert_sent=true
    # Warning: one account above warning threshold
    elif [[ "$acc1_usage" -ge "$WARNING_THRESHOLD" ]] || [[ "$acc2_usage" -ge "$WARNING_THRESHOLD" ]]; then
        if [[ -f "$NOTIFY" ]]; then
            "$NOTIFY" "warning" "system" "⚠️ Account usage alert:
Account 1: ${acc1_usage}%
Account 2: ${acc2_usage}%
Rotation recommended."
        fi
        date +%s > "$alert_file"
        alert_sent=true
    fi

    if [[ "$alert_sent" == "true" ]]; then
        echo "Alert sent"
    else
        echo "OK"
    fi
}

# Return account number (1 or 2) from recommendation
cmd_account_number() {
    local rec
    rec=$(cmd_recommend "$@" 2>/dev/null)
    if [[ "$rec" == "acc2" ]]; then
        echo "2"
    else
        echo "1"
    fi
}

# Main dispatch
case "${1:-status}" in
    recommend)
        cmd_recommend "$2"
        ;;
    account-number)
        cmd_account_number "$2"
        ;;
    status)
        cmd_status
        ;;
    check-alerts)
        cmd_check_alerts
        ;;
    help|*)
        echo "Usage: smart-rotate.sh <command> [args...]"
        echo ""
        echo "Commands:"
        echo "  recommend [session_num]  Recommend account (acc1/acc2)"
        echo "  account-number [num]     Get account number (1/2)"
        echo "  status                   Show both accounts' usage"
        echo "  check-alerts             Check and notify if high usage"
        ;;
esac
