# Claude Telegram Orchestrator - Architecture Documentation

## Overview

Control multiple Claude Code terminal sessions from your phone via Telegram. **No n8n required** - the Mac polls Telegram directly.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              YOUR PHONE                                      │
│                         Telegram App                                         │
│                    @gergo_netlock_claude_bot                                │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │
                              │ HTTPS (Telegram Bot API)
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TELEGRAM SERVERS                                     │
│                    api.telegram.org                                          │
│              Stores messages until polled                                    │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │
                              │ HTTP GET /getUpdates (polling every 5s)
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           YOUR MAC                                           │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    orchestrator.sh (LaunchAgent)                       │ │
│  │                                                                        │ │
│  │  • Runs on boot via LaunchAgent                                        │ │
│  │  • Polls Telegram API every 5 seconds                                  │ │
│  │  • Parses commands (/new, /kill, /status, /tts, /1, /2...)            │ │
│  │  • Detects replies → routes to correct session                         │ │
│  │  • Injects input to tmux sessions                                      │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│           ┌──────────────────┼──────────────────┐                           │
│           │                  │                  │                           │
│           ▼                  ▼                  ▼                           │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                     │
│  │   tmux      │    │   tmux      │    │   tmux      │                     │
│  │  claude-1   │    │  claude-2   │    │  claude-3   │                     │
│  │             │    │             │    │             │                     │
│  │ Claude Code │    │ Claude Code │    │ Claude Code │                     │
│  │ (dangerous) │    │ (dangerous) │    │ (dangerous) │                     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                     │
│         │                  │                  │                             │
│         └────────────┬─────┴─────┬────────────┘                             │
│                      │           │                                          │
│                      ▼           ▼                                          │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                 session-monitor.sh (per session)                       │ │
│  │                                                                        │ │
│  │  • Watches tmux pane output                                            │ │
│  │  • Detects: questions, errors, completions, multi-select menus         │ │
│  │  • Sends notifications to Telegram                                     │ │
│  │  • Writes TTS summary on session end                                   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                               │
│                              │ HTTP POST (sendMessage)                       │
│                              ▼                                               │
│                    Telegram Bot API                                          │
│                              │                                               │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
                               ▼
                         YOUR PHONE
                      (receives notification)
```

## NO n8n Involved

This system **does NOT use n8n**. It's a direct connection:

| Component | Role |
|-----------|------|
| Telegram Bot API | Message queue (stores messages until polled) |
| orchestrator.sh | Polls Telegram, processes commands, injects to tmux |
| session-monitor.sh | Watches Claude output, sends notifications back |
| tmux | Manages persistent terminal sessions |
| Claude Code | Runs in each tmux session with --dangerously-skip-permissions |

## File Structure

```
~/.claude/telegram-orchestrator/
├── config.env                 # Bot token, chat ID, settings
├── orchestrator.sh            # Main daemon (polls Telegram)
├── session-monitor.sh         # Monitors tmux for Claude events
├── start-claude.sh            # Creates new tmux + Claude session
├── notify.sh                  # Sends messages to Telegram
├── tg                         # Terminal helper command
├── sessions/                  # Active session tracking
│   ├── claude-1               # Session metadata JSON
│   ├── claude-1.monitor.pid   # Monitor process ID
│   └── ...
├── logs/                      # Log files
│   ├── orchestrator.log       # Main daemon log
│   ├── monitor-claude-1.log   # Per-session monitor logs
│   └── ...
├── README.md                  # Quick reference
└── ARCHITECTURE.md            # This file

~/Library/LaunchAgents/
└── com.claude.telegram-orchestrator.plist  # Auto-start on boot
```

## Message Flow

### Phone → Claude (Input)

```
1. You send "/1 yes, continue" in Telegram
                    │
                    ▼
2. Telegram stores message on their servers
                    │
                    ▼
3. orchestrator.sh polls: GET /getUpdates
                    │
                    ▼
4. Parses "/1 yes, continue" → session=claude-1, input="yes, continue"
                    │
                    ▼
5. tmux send-keys -t claude-1 "yes, continue"
   tmux send-keys -t claude-1 -H 0d   (hex Enter key)
                    │
                    ▼
6. Claude Code receives input and processes
```

### Claude → Phone (Output)

```
1. Claude produces output in tmux pane
                    │
                    ▼
2. session-monitor.sh captures pane every 2 seconds
                    │
                    ▼
3. Detects patterns:
   - Questions (?, y/n, confirm)
   - Errors (error:, failed)
   - Multi-select menus (❯, numbered lists)
   - Responses (⏺ marker)
                    │
                    ▼
4. notify.sh formats message with [claude-1] prefix
                    │
                    ▼
5. POST to Telegram: sendMessage
                    │
                    ▼
6. You see notification on phone
```

### Reply Routing

```
1. You receive message: "[claude-1] ❓ Do you want to proceed?"
                    │
                    ▼
2. You REPLY to this message with "yes"
                    │
                    ▼
3. orchestrator.sh receives update with reply_to_message
                    │
                    ▼
4. Extracts [claude-1] from original message text
                    │
                    ▼
5. Routes "yes" to claude-1 (not most recent session)
```

## Telegram Commands

| Command | Action |
|---------|--------|
| `/status` | List all active sessions with recent output |
| `/new` | Start new Claude session in ~/  |
| `/new <prompt>` | Start session with initial task |
| `/kill <n>` | Kill session claude-n |
| `/tts` | Toggle TTS read-aloud on/off |
| `/1 <msg>` | Send message to claude-1 |
| `/2 <msg>` | Send message to claude-2 |
| `/1 2` | Select option 2 in claude-1's menu |
| Any text | Send to most recent active session |
| Reply to msg | Route to session from original message |

## Key Technical Details

### Why tmux?
- Persistent sessions survive terminal close
- Multiple sessions can run simultaneously
- send-keys allows injecting input programmatically
- capture-pane allows reading output

### Why hex 0d for Enter?
Claude Code uses a custom terminal input handler (Ink/React). Standard `Enter` key name doesn't work. Hex `0d` (carriage return) does.

```bash
tmux send-keys -t claude-1 "hello"      # Types "hello"
tmux send-keys -t claude-1 -H 0d        # Presses Enter
```

### Why --dangerously-skip-permissions?
Without it, Claude asks for permission on every tool use. Since you're controlling remotely, you can't click Allow. This flag auto-approves.

### Rate Limiting
- Polling: every 5 seconds
- Notifications: minimum 10 seconds between same-type notifications
- Prevents spam when Claude produces lots of output

## Configuration

### config.env
```bash
TELEGRAM_BOT_TOKEN="8592331018:AAE..."  # From @BotFather
TELEGRAM_CHAT_ID="302680207"            # Your Telegram user ID
N8N_BASE_URL="https://n8n.dev.netlock.cloud"  # Not used currently
POLL_INTERVAL=5                         # Seconds between polls
MAX_SESSIONS=5                          # Maximum concurrent sessions
```

### TTS Toggle
```bash
# Enable TTS read-aloud
touch ~/.claude/tts/enabled

# Disable TTS (default)
rm ~/.claude/tts/enabled

# Or use Telegram command
/tts
```

## Startup

The orchestrator starts automatically on Mac boot via LaunchAgent.

Manual control:
```bash
# Start
launchctl load ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist

# Stop
launchctl unload ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist

# Check status
ps aux | grep orchestrator
```

## Logs

```bash
# Main orchestrator log
tail -f ~/.claude/telegram-orchestrator/logs/orchestrator.log

# Session monitor logs
tail -f ~/.claude/telegram-orchestrator/logs/monitor-claude-1.log

# LaunchAgent logs
tail -f ~/.claude/telegram-orchestrator/logs/launchd.out.log
tail -f ~/.claude/telegram-orchestrator/logs/launchd.err.log
```

## Troubleshooting

### Messages not being received
```bash
# Check if orchestrator is running
ps aux | grep orchestrator

# Check logs
tail -20 ~/.claude/telegram-orchestrator/logs/orchestrator.log

# Test Telegram API directly
curl "https://api.telegram.org/bot$TOKEN/getUpdates"
```

### Sessions not appearing in Cursor
```bash
# Check if session exists
tmux ls

# Manually attach
tmux attach -t claude-1

# Check AppleScript permissions in System Preferences → Privacy → Accessibility
```

### Claude not responding to input
```bash
# Check if Enter key is working
tmux send-keys -t claude-1 "test"
tmux send-keys -t claude-1 -H 0d

# Capture current pane
tmux capture-pane -t claude-1 -p
```

### No notifications from Claude
```bash
# Check if monitor is running
ps aux | grep session-monitor

# Check monitor log
tail -20 ~/.claude/telegram-orchestrator/logs/monitor-claude-1.log

# Restart monitor
pkill -f "session-monitor.sh claude-1"
nohup ~/.claude/telegram-orchestrator/session-monitor.sh claude-1 &
```

## Security Notes

- Bot token in config.env - don't commit to git
- Only your chat ID can control sessions
- Sessions run with --dangerously-skip-permissions
- No external servers involved except Telegram API
