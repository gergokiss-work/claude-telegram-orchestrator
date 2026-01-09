# Claude Telegram Orchestrator

Control Claude Code sessions from Telegram on your phone. Send text or voice messages, get summaries back.

## How It Works

```
Phone (Telegram)                    Mac
     │                               │
     │  "fix the auth bug"           │
     ├──────────────────────────────>│ orchestrator.sh receives
     │                               │ routes to claude-0 (coordinator)
     │                               │
     │                               │ claude-0 handles or spawns worker
     │                               │ Claude calls send-summary.sh
     │                               │
     │  [claude-0] Starting worker   │
     │<──────────────────────────────┤
     │  for auth bug fix...          │
     │                               │
     │  (reply to [claude-X] to      │
     │   talk to that session)       │
     └───────────────────────────────┘
```

## Architecture

```
claude-0 (coordinator) ← Always running, receives non-reply messages
    │
    ├── claude-1 (work session) ← Reply to [claude-1] messages
    ├── claude-2 (work session) ← Reply to [claude-2] messages
    └── claude-3 (work session) ← Reply to [claude-3] messages
```

- **claude-0**: Persistent coordinator, handles general requests, can spawn workers
- **claude-1, 2, 3...**: Work sessions for specific tasks, spawned on demand
- **Reply routing**: Reply to any `[claude-X]` message to talk to that specific session

## Features

- **Text messages** - Send tasks directly
- **Voice messages** - Transcribed via Whisper API
- **Multiple sessions** - Run claude-1, claude-2, etc. simultaneously
- **Reply routing** - Reply to a `[claude-X]` message to continue with that session
- **Immediate feedback** - Claude sends summaries directly (no waiting)

## Commands

| Command | Description |
|---------|-------------|
| `/new` | Start new Claude session |
| `/new fix the bug` | Start with initial task |
| `/resume the auth bug` | Resume a previous session by description |
| `/status` | List active sessions |
| `/kill 2` | Stop session claude-2 |
| `/tts` | Toggle TTS on Mac |

## Routing Messages

**Default:** Messages go to `claude-0` (the coordinator).

**Specific session:** Reply to any `[claude-X]` tagged message - your reply goes to that session.

## Setup

### Prerequisites

- macOS with Homebrew
- Claude Code CLI (`claude`)
- tmux, jq, curl

### 1. Create Telegram Bot

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot`, follow prompts
3. Copy the bot token

### 2. Configure

```bash
cd ~/.claude/telegram-orchestrator

# Copy example config
cp config.env.example config.env

# Create secrets file
cat > .env.local << 'EOF'
TELEGRAM_BOT_TOKEN="your-bot-token-here"
TELEGRAM_CHAT_ID=""  # Auto-detected on first message
OPENAI_API_KEY="sk-..."  # For voice transcription
EOF
```

### 3. Set Bot Commands

```bash
# Run once to register commands with Telegram
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" \
  -H "Content-Type: application/json" \
  -d '{
    "commands": [
      {"command": "status", "description": "List active Claude sessions"},
      {"command": "new", "description": "Start new Claude session"},
      {"command": "resume", "description": "Resume session by description"},
      {"command": "kill", "description": "Stop a session (e.g. /kill 1)"},
      {"command": "tts", "description": "Toggle TTS read-aloud"}
    ]
  }'
```

### 4. Install LaunchAgent (Auto-start)

```bash
mkdir -p ~/Library/LaunchAgents

cat > ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.telegram-orchestrator</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/YOUR_USERNAME/.claude/telegram-orchestrator/orchestrator.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/YOUR_USERNAME/.claude/telegram-orchestrator/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOUR_USERNAME/.claude/telegram-orchestrator/logs/launchd.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

# Replace YOUR_USERNAME
sed -i '' "s/YOUR_USERNAME/$USER/g" ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist

# Load
launchctl load ~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist
```

### 5. Enable

```bash
touch ~/.claude/telegram-orchestrator/enabled
```

## Resuming Previous Sessions

Use `/resume` with a natural language description to find and resume a previous session:

```
/resume the auth bug fix
/resume telegram format work
/resume react component refactor
```

The system searches your Claude history (`~/.claude/history.jsonl`) and uses AI to find the best matching session, then starts a new Claude instance with that session's context restored.

**Requirements:** Set `ANTHROPIC_API_KEY` in `.env.local` for semantic search (falls back to keyword matching without it).

## File Structure

```
~/.claude/telegram-orchestrator/
├── orchestrator.sh      # Main daemon - polls Telegram, routes messages
├── send-summary.sh      # Sends summaries to Telegram immediately
├── notify.sh            # System notifications (errors, status)
├── start-claude.sh      # Creates new Claude tmux sessions
├── find-session.sh      # Finds sessions by natural language query
├── coordinator-claude.md # Special instructions for claude-0 coordinator
├── config.env           # Settings (poll interval, max sessions)
├── .env.local           # Secrets (bot token, API keys) - gitignored
├── enabled              # Touch to enable, rm to disable
├── sessions/            # Active session tracking
├── logs/                # Runtime logs
└── src/voice/
    └── transcribe.sh    # Whisper API transcription
```

## How Claude Sends Summaries

When a message comes from Telegram, the orchestrator appends a tag: `<tg>send-summary.sh</tg>`

Claude sees this and knows to send a summary when done:

```bash
# IMPORTANT: Use --session flag to include [claude-X] tag for reply routing
~/.claude/telegram-orchestrator/send-summary.sh --session $(tmux display-message -p '#S') "Your summary here"
```

The script:
1. Uses `--session` flag to identify which session is sending
2. Tags the message with `[claude-X]` for reply routing
3. Sends immediately to Telegram

### Message Format

See `TELEGRAM_FORMAT.md` for the standard format:
```
{STATUS_EMOJI} <b>{Title}</b>

🎯 <b>Request:</b> What was asked
📋 <b>Result:</b>
• Key points
💡 <i>Next steps</i>
```

## Coordinator (claude-0)

The coordinator session runs persistently and:
- Receives all non-reply messages
- Can spawn worker sessions (claude-1, claude-2...)
- Delegates tasks and monitors progress
- Injects tasks to other sessions via tmux

### Coordinator System Prompt

`start-claude.sh --coordinator` appends `coordinator-claude.md` to claude-0's system prompt, giving it:
- Exact tmux injection commands
- Session checking patterns
- Troubleshooting knowledge
- Routing responsibilities

## Troubleshooting

### Check if running

```bash
ps aux | grep orchestrator
```

### View logs

```bash
tail -f ~/.claude/telegram-orchestrator/logs/orchestrator.log
```

### Restart

```bash
launchctl stop com.claude.telegram-orchestrator
launchctl start com.claude.telegram-orchestrator
```

### Not receiving messages?

1. Check bot token is correct in `.env.local`
2. Check `enabled` file exists
3. Send `/status` - if no response, orchestrator isn't running
4. Check logs for errors

### Voice messages not working?

1. Check `OPENAI_API_KEY` in `.env.local`
2. Check `logs/voice.log` for errors

## Configuration

### config.env

```bash
POLL_INTERVAL=5      # Telegram polling interval (seconds)
MAX_SESSIONS=5       # Maximum concurrent Claude sessions
```

### .env.local (secrets)

```bash
TELEGRAM_BOT_TOKEN="..."   # From BotFather
TELEGRAM_CHAT_ID="..."     # Auto-detected or manual
OPENAI_API_KEY="..."       # For Whisper voice transcription
ANTHROPIC_API_KEY="..."    # For semantic /resume search (optional)
```

## License

MIT
