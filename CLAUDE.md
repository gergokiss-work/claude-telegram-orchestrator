# Telegram-Claude Orchestrator

Control multiple Claude Code sessions from Telegram.

## Quick Start

```bash
# Start orchestrator (polls Telegram, manages sessions)
~/.claude/telegram-orchestrator/orchestrator.sh

# Or via launchd (auto-starts on boot)
launchctl load ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist
```

## Architecture

```
Telegram App (phone)
       ↓
Telegram Bot API
       ↓
orchestrator.sh (polls every 5s)
       ↓
tmux sessions: claude-0, claude-1, claude-2...
```

## Telegram Commands

| Command | Action |
|---------|--------|
| `/status` | Show all sessions with state (thinking/idle) |
| `/new` | Start new Claude session |
| `/new <prompt>` | Start session with initial task |
| `/kill <N>` | Kill session claude-N |
| `/resume <query>` | Find and resume past session |
| (any text) | Sent to claude-0 (coordinator) |
| (reply to msg) | Sent to session that sent original msg |

## Session States

| Icon | State | Meaning |
|------|-------|---------|
| ⏳ | thinking | Actively processing (spinner visible) |
| 🟢 | idle | Ready for new task |
| 🎯 | coordinator | claude-0 (receives all non-routed messages) |

## Key Files

| File | Purpose |
|------|---------|
| `orchestrator.sh` | Main daemon - polls Telegram, routes messages |
| `start-claude.sh` | Creates new tmux session with Claude |
| `send-summary.sh` | Send formatted message to Telegram |
| `notify.sh` | Send notification (used by hooks) |
| `find-session.sh` | Search past sessions by keyword |
| `.env.local` | Secrets (TELEGRAM_BOT_TOKEN, OPENAI_API_KEY) |
| `config.env` | Settings (POLL_INTERVAL, MAX_SESSIONS) |

## claude-0 (Coordinator)

The always-running default instance that:
- Receives all Telegram messages not routed to specific sessions
- Can spawn/manage other sessions
- Handles `/status`, `/new`, `/kill` commands
- Routes messages based on reply-to

### Starting claude-0

```bash
~/.claude/telegram-orchestrator/start-claude.sh --coordinator
```

## Message Flow

**Telegram → Claude:**
1. You send message to bot
2. orchestrator.sh polls and receives it
3. Injects into appropriate tmux session
4. Appends `<tg>send-summary.sh</tg>` tag

**Claude → Telegram:**
1. Claude sees `<tg>send-summary.sh</tg>` tag
2. Runs `send-summary.sh` with formatted response
3. You receive reply in Telegram

## Auto-Start on Boot

LaunchAgent at `~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist`

```bash
# Load (enable)
launchctl load ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist

# Unload (disable)
launchctl unload ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist

# Check status
launchctl list | grep claude
```

## Troubleshooting

**Orchestrator not running:**
```bash
# Check if running
ps aux | grep orchestrator

# Check logs
tail -50 ~/.claude/telegram-orchestrator/logs/orchestrator.log
```

**Messages not arriving:**
```bash
# Test Telegram API
source ~/.claude/telegram-orchestrator/.env.local
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
```

**Duplicate processes:**
```bash
# Kill all and restart
pkill -9 -f orchestrator.sh
rm -f ~/.claude/telegram-orchestrator/.orchestrator.lock
~/.claude/telegram-orchestrator/orchestrator.sh
```
