# Claude Telegram Orchestrator

Control multiple Claude Code terminal sessions from your phone via Telegram.

```
Phone (Telegram) ←→ Telegram API ←→ Your Mac (polls every 5s) ←→ Claude Code
```

## Features

- 📱 Start/stop Claude sessions from your phone
- 💬 Send messages to any session
- 🔔 Get notified when Claude asks questions or finishes
- ↩️ Reply to messages to route to correct session
- 🖥️ Auto-opens sessions in Cursor
- 🔊 Optional TTS read-aloud (toggleable)

---

## Installation (5 minutes)

### Step 1: Create Telegram Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot`
3. Choose a name (e.g., "My Claude Bot")
4. Choose a username (e.g., "my_claude_bot")
5. **Copy the bot token** (looks like `123456789:ABCdefGHI...`)

### Step 2: Run Installer

```bash
# Clone this repo
git clone <repo-url> ~/claude-telegram-orchestrator
cd ~/claude-telegram-orchestrator

# Run installer
./install.sh
```

The installer will:
- Check dependencies (tmux, jq, claude)
- Ask for your bot token
- Auto-detect your Chat ID (send a message to your bot when prompted)
- Install all scripts to `~/.claude/telegram-orchestrator/`
- Set up auto-start on boot
- Configure the `tg` terminal command

### Step 3: Test It

From Telegram, send to your bot:
```
/new hello world
```

You should see:
1. ✅ Notification confirming session started
2. 🖥️ Cursor opens with the session attached
3. 📝 Claude's response in Telegram

---

## Usage

### Telegram Commands

| Command | Action |
|---------|--------|
| `/new` | Start new Claude session |
| `/new fix the login bug` | Start with initial task |
| `/status` | List all active sessions |
| `/kill 1` | Kill session claude-1 |
| `/tts` | Toggle TTS read-aloud |
| `/1 yes` | Send "yes" to session 1 |
| `/1 2` | Select option 2 in session 1's menu |
| Any text | Send to most recent session |
| **Reply to message** | Route to that session |

### Terminal Commands

```bash
tg status       # List active sessions
tg new          # Start new session
tg new "task"   # Start with initial task
tg attach 1     # Attach to session 1
tg kill 1       # Kill session 1
tg logs         # View orchestrator logs
tg start        # Start daemon
tg stop         # Stop daemon
```

### tmux Shortcuts

| Keys | Action |
|------|--------|
| `Ctrl+B` then `D` | Detach (leave running) |
| `Ctrl+B` then `S` | Switch sessions |
| `tmux ls` | List all sessions |

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         YOUR MAC                                 │
│                                                                  │
│  orchestrator.sh (runs on boot)                                  │
│       │                                                          │
│       ├── Polls Telegram every 5 seconds                         │
│       ├── Parses commands (/new, /kill, /1, etc.)               │
│       └── Routes messages to correct tmux session                │
│                                                                  │
│  tmux sessions                                                   │
│       │                                                          │
│       ├── claude-1: Claude Code (--dangerously-skip-permissions) │
│       ├── claude-2: Claude Code                                  │
│       └── claude-3: Claude Code                                  │
│                                                                  │
│  session-monitor.sh (per session)                                │
│       │                                                          │
│       ├── Watches Claude output                                  │
│       ├── Detects questions, errors, completions                 │
│       └── Sends notifications to Telegram                        │
└─────────────────────────────────────────────────────────────────┘
```

**No cloud servers required** - everything runs locally on your Mac, communicating directly with Telegram's API.

---

## Configuration

Edit `~/.claude/telegram-orchestrator/config.env`:

```bash
TELEGRAM_BOT_TOKEN="your-token"
TELEGRAM_CHAT_ID="your-chat-id"
POLL_INTERVAL=5          # Seconds between polls
MAX_SESSIONS=5           # Max concurrent sessions
```

---

## Troubleshooting

### Not receiving messages from Telegram

```bash
# Check if orchestrator is running
ps aux | grep orchestrator

# View logs
tg logs

# Restart
tg stop && tg start
```

### Sessions not opening in Cursor

1. Check System Preferences → Privacy → Accessibility
2. Ensure "Cursor" has permission
3. Restart Cursor

### Claude not responding to input

```bash
# Check session exists
tmux ls

# Manually test input
tmux send-keys -t claude-1 "hello"
tmux send-keys -t claude-1 -H 0d
```

### No notifications

```bash
# Check monitor is running
ps aux | grep session-monitor

# Check monitor log
tail -20 ~/.claude/telegram-orchestrator/logs/monitor-claude-1.log
```

---

## Uninstall

```bash
# Stop daemon
tg stop

# Remove LaunchAgent
rm ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist

# Remove files
rm -rf ~/.claude/telegram-orchestrator

# Remove alias from .zshrc/.bashrc
# (manually remove the "Claude Telegram Orchestrator" lines)
```

---

## Requirements

- macOS (tested on Sonoma)
- [Claude Code CLI](https://claude.ai/code)
- [Homebrew](https://brew.sh)
- Telegram account

---

## License

MIT - Use freely, modify as needed.
