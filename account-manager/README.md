# Account Manager

Multi-account usage monitoring and smart rotation for Claude Code sessions.

## Overview

Manages two Claude Code accounts with separate rate limits, monitoring their usage via the tmux statusbar and automatically swapping sessions between accounts when limits are reached.

### Accounts

| Account | Tag | Email | Config Dir |
|---------|-----|-------|------------|
| 1 (ns) | `ns` | `gergo.kiss@netlocksolutions.com` | `~/.claude` (default) |
| 2 (nl) | `nl` | `kiss.gergo@netlock.hu` | `~/.claude-account2` |

### Architecture

```
tmux statusbar
    └── statusline.sh (reads cache files)

usage-monitor.sh (daemon, every 5 min)
    ├── fetch-usage.sh 1 → OAuth API → account1-usage-cache.json
    └── fetch-usage.sh 2 → fetch-nl-browser.sh → account2-usage-cache.json
                               ├── Method 1: osascript Chrome JS
                               ├── Method 2: Chrome MCP result file
                               └── Fallback: cached data (15 min TTL)
```

## Scripts

### `fetch-usage.sh <1|2>`
Main entry point. Fetches usage for the specified account.
- **Account 1**: Uses OAuth API (`api.anthropic.com/api/oauth/usage`) — works correctly.
- **Account 2**: Delegates to `fetch-nl-browser.sh` because the OAuth API returns wrong (ns-scoped) data for nl tokens due to a multi-org token scoping issue.

### `fetch-nl-browser.sh`
Browser-based usage fetcher for the nl account. Fetches from `claude.ai/api/organizations/{org_id}/usage` via the Chrome browser context.

**Methods (tried in order):**
1. **osascript**: Executes synchronous XHR in a Chrome tab logged into claude.ai. Requires "Allow JavaScript from Apple Events" enabled in Chrome (View → Developer menu). Has 10s timeout to prevent hangs.
2. **Chrome MCP result**: Checks if a Claude session with Chrome MCP recently wrote fresh data to `.nl-refresh-result`.
3. **Cache fallback**: Uses existing cache if < 15 min old. After 15 min, preserves data but adds `_stale: true` flag.

### `refresh-nl-cache.sh`
Helper for Chrome MCP sessions to update the nl cache. Accepts JSON via stdin or argument.

```bash
# From a Chrome MCP Claude session:
echo '{"five_hour":{"utilization":9,...},...}' | refresh-nl-cache.sh
```

### `usage-monitor.sh`
Background daemon that polls usage every 5 minutes and triggers alerts:

| Threshold | Action |
|-----------|--------|
| 5h ≥ 80% | TTS heads-up |
| 5h ≥ 93% | Auto-swap + handoff |
| 5h = 100% | Blocked notification |
| 7d ≥ 70% | Telegram warning |
| 7d ≥ 85% | Inject agent warnings |
| 7d ≥ 95% | Auto-swap + handoff |

### `auto-swap.sh`
Automatically swaps sessions between accounts when usage thresholds are hit.

### `smart-rotate.sh`
Intelligent account rotation based on current usage levels.

## Statusbar Format

```
ns:11%/12%w@18:00 nl:9%/32%w@16:00
│   │    │    │
│   │    │    └── 5h window reset time (local)
│   │    └── 7d weekly usage %
│   └── 5h session usage %
└── account tag
```

**Indicators:**
- `⚠` = 5h ≥ 80%
- `❌` = 5h blocked (100%)
- `🔴` = 7d ≥ 85%
- `⚡` = monthly burst exhausted
- `📡` = data stale (browser scrape older than 15 min)
- `🔑❌` = token expired
- `🔑🚫` = token revoked
- `📡?` = no browser data available

## Why Browser Scraping for Account 2?

The Anthropic OAuth API (`api.anthropic.com/api/oauth/usage`) always returns usage scoped to the **primary organization** (ns), regardless of which account authorized the token. This is a multi-org token scoping issue — new OAuth tokens always bind to the ns org.

The `claude.ai/api/organizations/{org_id}/usage` endpoint returns correct per-org usage, but it's protected by Cloudflare and only accessible from a browser session with valid cookies. Direct curl access fails (Cloudflare JS challenge).

The browser scraping approach (osascript or Chrome MCP) works because it executes the fetch within Chrome's authenticated session context.

## Setup

1. **Start the monitor daemon:**
   ```bash
   nohup ~/.claude/account-manager/usage-monitor.sh &
   ```

2. **Enable automatic browser scraping (recommended):**
   In Chrome: View → Developer → Allow JavaScript from Apple Events

3. **Manual refresh via Chrome MCP (if osascript not available):**
   From a Claude session with Chrome MCP access, fetch and pipe to `refresh-nl-cache.sh`.

## Cache Files

| File | Source | Content |
|------|--------|---------|
| `account1-usage-cache.json` | OAuth API | ns usage data |
| `account2-usage-cache.json` | Browser scrape | nl usage data |
| `.nl-refresh-result` | Chrome MCP | Latest MCP scrape (used by fetch-nl-browser.sh) |
