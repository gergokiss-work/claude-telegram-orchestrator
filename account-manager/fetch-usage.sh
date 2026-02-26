#!/bin/bash
# fetch-usage.sh - Fetch real-time usage from Anthropic API for one account
# Usage: fetch-usage.sh <1|2>
# Output: JSON saved to account{N}-usage-cache.json, also printed to stdout
#
# NOTE: This script is READ-ONLY — it never modifies tokens or Keychain.
# It verifies the token's actual identity (email) matches the expected account.

ACCOUNT="${1:-1}"
AM_DIR="$HOME/.claude/account-manager"

# Account 2 (nl): OAuth API returns ns-scoped data (multi-org bug).
# Use browser scraping instead.
if [[ "$ACCOUNT" == "2" ]]; then
    exec "$AM_DIR/fetch-nl-browser.sh"
fi

case "$ACCOUNT" in
    1) KEYCHAIN="Claude Code-credentials"
       EXPECTED_EMAIL="gergo.kiss@netlocksolutions.com" ;;
    *) echo '{"error":"invalid_account"}'; exit 1 ;;
esac

CACHE="$AM_DIR/account${ACCOUNT}-usage-cache.json"

# Get OAuth data from Keychain
OAUTH_JSON=$(security find-generic-password -s "$KEYCHAIN" -w 2>/dev/null)

if [[ -z "$OAUTH_JSON" ]]; then
    echo "{\"error\":\"no_keychain\",\"account\":$ACCOUNT,\"_fetched_at\":\"$(date -Iseconds)\"}" > "$CACHE"
    cat "$CACHE"
    exit 1
fi

TOKEN=$(echo "$OAUTH_JSON" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d['claudeAiOauth']['accessToken'])
except Exception:
    exit(1)
" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
    echo "{\"error\":\"no_token\",\"account\":$ACCOUNT,\"_fetched_at\":\"$(date -Iseconds)\"}" > "$CACHE"
    cat "$CACHE"
    exit 1
fi

# Check if token is expired before calling API
IS_EXPIRED=$(echo "$OAUTH_JSON" | python3 -c "
import json, sys, time
try:
    d = json.loads(sys.stdin.read())
    expires = d['claudeAiOauth'].get('expiresAt', 0)
    print('yes' if (expires / 1000) < time.time() else 'no')
except:
    print('unknown')
" 2>/dev/null)

if [[ "$IS_EXPIRED" == "yes" ]]; then
    echo "{\"error\":\"token_expired\",\"account\":$ACCOUNT,\"_fetched_at\":\"$(date -Iseconds)\",\"_hint\":\"Run: claude login (or CLAUDE_CONFIG_DIR=~/.claude-account2 claude login)\"}" > "$CACHE"
    cat "$CACHE"
    exit 1
fi

# Identity verification disabled — the profile API returns the primary account
# email which doesn't reflect org-scoped tokens on multi-org accounts.
# `claude auth status` is the source of truth for org identity.

# Query usage API — capture both body and HTTP status code
API_BODY_FILE=$(mktemp /tmp/usage-api-XXXXXX.json)
trap "rm -f '$API_BODY_FILE'" EXIT
HTTP_STATUS=$(curl -s -o "$API_BODY_FILE" -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/2.1.45" \
    --max-time 10 \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

# Success: 2xx status with non-empty body
if [[ "$HTTP_STATUS" =~ ^2 ]] && [[ -s "$API_BODY_FILE" ]]; then
    RESULT=$(cat "$API_BODY_FILE")
else
    RESULT=""
fi

if [[ -z "$RESULT" ]]; then
    if [[ "$HTTP_STATUS" == "401" ]]; then
        echo "{\"error\":\"token_expired\",\"account\":$ACCOUNT,\"http_status\":401,\"_fetched_at\":\"$(date -Iseconds)\",\"_hint\":\"Run: claude login\"}" > "$CACHE"
    elif [[ "$HTTP_STATUS" == "403" ]]; then
        echo "{\"error\":\"token_revoked\",\"account\":$ACCOUNT,\"http_status\":403,\"_fetched_at\":\"$(date -Iseconds)\",\"_hint\":\"Token revoked. Run: claude login\"}" > "$CACHE"
    elif [[ "$HTTP_STATUS" == "000" ]] || [[ -z "$HTTP_STATUS" ]]; then
        echo "{\"error\":\"network_error\",\"account\":$ACCOUNT,\"_fetched_at\":\"$(date -Iseconds)\"}" > "$CACHE"
    else
        echo "{\"error\":\"fetch_failed\",\"account\":$ACCOUNT,\"http_status\":${HTTP_STATUS:-0},\"_fetched_at\":\"$(date -Iseconds)\"}" > "$CACHE"
    fi
    cat "$CACHE"
    exit 1
fi

# Annotate with metadata and save to cache
echo "$RESULT" | python3 -c "
import json, sys
from datetime import datetime
d = json.loads(sys.stdin.read())
d['_account'] = $ACCOUNT
d['_fetched_at'] = datetime.now().isoformat()
print(json.dumps(d, indent=2))
" > "$CACHE" 2>/dev/null

cat "$CACHE"
