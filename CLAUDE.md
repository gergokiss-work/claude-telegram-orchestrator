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
| `send-file.sh` | Send files (PDF, images, video, etc.) to Telegram |
| `notify.sh` | Send notification (used by hooks) |
| `find-session.sh` | Search past sessions by keyword |
| `.env.local` | Secrets (TELEGRAM_BOT_TOKEN, OPENAI_API_KEY) |
| `config.env` | Settings (POLL_INTERVAL, MAX_SESSIONS) |

## claude-0 (Coordinator)

The always-running default instance that:
- Receives all Telegram messages not routed to specific sessions
- Can spawn/manage other sessions
- Delegates tasks to worker sessions (claude-1, claude-2, etc.)
- Monitors session status and reports back

### Starting claude-0

```bash
~/.claude/telegram-orchestrator/start-claude.sh --coordinator
```

### Injecting Tasks to Other Sessions

When user asks to send a task to another session (e.g., "tell claude-2 to..."):

```bash
# Clear any leftover input first
tmux send-keys -t claude-2 C-u

# Inject the prompt
INPUT="Your task here
<tg>send-summary.sh</tg>"

tmpfile=$(mktemp)
printf '%s' "$INPUT" > "$tmpfile"
tmux load-buffer -b tg_msg "$tmpfile"
tmux paste-buffer -b tg_msg -t claude-2
tmux delete-buffer -b tg_msg 2>/dev/null
rm -f "$tmpfile"

# Send Enter to submit
sleep 0.5
tmux send-keys -t claude-2 Enter
```

### Resuming Past Sessions

Use `find-session.sh` to search by keyword, then start with `--resume`:

```bash
# Find session about "n8n"
SESSION_ID=$(~/.claude/telegram-orchestrator/find-session.sh "n8n")

# Resume it
~/.claude/telegram-orchestrator/start-claude.sh --resume "$SESSION_ID" --query "n8n"
```

### Coordinator Responsibilities

1. **Route messages** - Send tasks to appropriate worker sessions
2. **Monitor status** - Check on sessions via tmux capture-pane
3. **Report back** - Always send summaries via send-summary.sh
4. **Delegate** - Don't do everything yourself, spawn/use worker sessions

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

## Responding to Telegram Messages

When you see `<tg>send-summary.sh</tg>` at the end of a message, you MUST:

1. **Read the format template first:** `~/.claude/telegram-orchestrator/TELEGRAM_FORMAT.md`
2. **Send a formatted summary** using that template structure

```bash
# Include your session name for reply routing!
~/.claude/telegram-orchestrator/send-summary.sh --session $(tmux display-message -p '#S') "YOUR_FORMATTED_MESSAGE"
```

**Quick Format Reference:**
```
{STATUS_EMOJI} <b>{Title}</b>

🎯 <b>Request:</b> What was asked
📋 <b>Result:</b>
• Key points as bullets
💡 <i>Notes or next steps</i>
```

**Status Emojis:** ✅ Done | ⏳ Working | ❌ Failed | 💡 Info | ⚠️ Warning

**Rules:**
- User can't see the Mac screen - provide full context
- Include: what was asked, what was done, results, any blockers
- Keep readable but complete - use bullets for scannability

## Sending Files to Telegram

Use `send-file.sh` to send PDFs, images, videos, or any file to Telegram:

```bash
# Basic - send a file
~/.claude/telegram-orchestrator/send-file.sh /path/to/report.pdf

# With session tag (for reply routing)
~/.claude/telegram-orchestrator/send-file.sh --session $(tmux display-message -p '#S') /path/to/file.pdf

# With caption
~/.claude/telegram-orchestrator/send-file.sh --session $(tmux display-message -p '#S') --caption "Here's the report" /path/to/report.pdf

# Caption as positional arg
~/.claude/telegram-orchestrator/send-file.sh --session $(tmux display-message -p '#S') /path/to/file.pdf "Optional caption"
```

**Auto-detection:** Images send as photos (inline preview), videos as video, audio as audio, everything else (PDF, zip, etc.) as documents. Max file size: 50MB.

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
