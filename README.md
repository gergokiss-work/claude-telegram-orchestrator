# Claude Telegram Orchestrator

Control multiple Claude Code sessions from your phone via Telegram. Send text or voice messages, get summaries back, manage autonomous task loops.

## Features

- **Multi-session management** - Run claude-0 (coordinator) + unlimited worker sessions
- **Voice messages** - Transcribed via OpenAI Whisper API
- **Reply routing** - Reply to any `[claude-X]` message to talk to that session
- **RALPH integration** - Autonomous task loops with circuit breaker protection
- **Watchdog** - Auto-fixes stuck sessions, sends reminders
- **Multi-account support** - Switch between Claude accounts to avoid rate limits
- **Context-aware auto-respawn** - Sessions auto-handoff at configurable threshold
- **Input sanitization** - Strips shell metacharacters from Telegram input before tmux injection
- **tmux session logging** - All sessions auto-logged to files, searchable by any Claude instance
- **Restart all sessions** - Graceful restart with handoff continuity (new version, crashes, shutdown)
- **Smart account rotation** - Intelligent account selection based on usage tracking
- **TTS priority queue** - Priority-aware text-to-speech notifications
- **Handoff action logging** - Auto-categorized progress tracking in handoff files

## Architecture

```
Phone (Telegram)                         Mac
     │                                    │
     │  "fix the auth bug"                │
     ├───────────────────────────────────>│ orchestrator.sh receives
     │                                    │ routes to claude-0
     │                                    │
     │                                    │ claude-0 spawns worker
     │  [claude-1] Working on auth...     │
     │<───────────────────────────────────┤
     │                                    │
     │  (reply to continue with           │
     │   that specific session)           │
     └────────────────────────────────────┘

Session Architecture:
┌─────────────────────────────────────────────────┐
│ claude-0 (coordinator) - Always running         │
│     │                                           │
│     ├── claude-1 (worker) - Specific tasks      │
│     ├── claude-2 (worker) - Specific tasks      │
│     └── claude-3 (worker) - Specific tasks      │
│                                                 │
│ watchdog (monitor) - Fixes stuck sessions       │
│ ralph-worker (autonomous) - Task loops          │
└─────────────────────────────────────────────────┘
```

## Telegram Commands

### Session Management

| Command | Description |
|---------|-------------|
| `/status` | Rich status: sessions, context %, account info |
| `/sessions` | List all active tmux sessions |
| `/new` | Start new Claude session |
| `/new <prompt>` | Start session with initial task |
| `/kill <N>` | Stop session claude-N |
| `/resume <query>` | Find and resume past session by description |
| `/inject <N> <msg>` | Inject message directly to session N |

### Monitoring & Debug

| Command | Description |
|---------|-------------|
| `/context [N]` | Show context % for session N (or all) |
| `/logs [N]` | Get recent logs from session N |
| `/handoffs` | List recent handoff files |
| `/respawn <N>` | Manual respawn trigger for session N |

### Watchdog

| Command | Description |
|---------|-------------|
| `/watchdog` | Show watchdog status |
| `/watchdog start [sessions...]` | Start watching (empty = reminder-only) |
| `/watchdog stop` | Stop watchdog |
| `/watchdog add <N>` | Add session to watch list |
| `/watchdog remove <N>` | Remove from watch list |

### RALPH (Autonomous Tasks)

| Command | Description |
|---------|-------------|
| `/ralph` | Show RALPH help |
| `/ralph start <N> <task>` | Start task on session N |
| `/ralph loop <N> [max]` | Start autonomous loop (default: 100) |
| `/ralph status [N]` | Show worker status |
| `/ralph stop <N>` | Stop worker loop |
| `/ralph cancel <N>` | Cancel task entirely |
| `/ralph list` | Show active tasks |
| `/ralph reset <N>` | Reset circuit breaker |

### Circuit Breaker

| Command | Description |
|---------|-------------|
| `/circuit [N]` | Show circuit breaker status |
| `/circuit <N> reset` | Reset circuit breaker for session |

### Account Management

| Command | Description |
|---------|-------------|
| `/account` | Show current account |
| `/account 1` | Switch to account 1 |
| `/account 2` | Switch to account 2 |
| `/account rotate` | Toggle between accounts |
| `/migrate <N> [1\|2]` | Migrate session to other account |

### Other

| Command | Description |
|---------|-------------|
| `/tts` | Toggle TTS on Mac |
| `/tts on/off/status` | Control TTS explicitly |
| `/help` | Show help message |

## Message Routing

- **Default:** Messages go to `claude-0` (coordinator)
- **Reply routing:** Reply to any `[claude-X]` tagged message → goes to that session
- **Direct inject:** `/inject N <message>` sends directly to session N

## Setup

### Prerequisites

- macOS with Homebrew
- Claude Code CLI (`claude`)
- tmux, jq, curl
- Node.js (for some features)

### 1. Create Telegram Bot

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot`, follow prompts
3. Copy the bot token

### 2. Configure

```bash
cd ~/.claude/telegram-orchestrator

# Create secrets file
cat > .env.local << 'EOF'
TELEGRAM_BOT_TOKEN="your-bot-token-here"
TELEGRAM_CHAT_ID=""  # Auto-detected on first message
OPENAI_API_KEY="sk-..."  # For voice transcription
EOF

# Copy example config if needed
cp config.env.example config.env
```

### 3. Set Bot Commands (Optional)

```bash
source .env.local
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" \
  -H "Content-Type: application/json" \
  -d '{
    "commands": [
      {"command": "status", "description": "Show sessions with context %"},
      {"command": "new", "description": "Start new Claude session"},
      {"command": "kill", "description": "Stop a session (e.g. /kill 1)"},
      {"command": "resume", "description": "Resume session by description"},
      {"command": "watchdog", "description": "Watchdog status/control"},
      {"command": "ralph", "description": "Autonomous task management"},
      {"command": "account", "description": "Account management"},
      {"command": "tts", "description": "Toggle TTS read-aloud"},
      {"command": "help", "description": "Show all commands"}
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

## File Structure

```
~/.claude/telegram-orchestrator/
├── orchestrator.sh          # Main daemon - polls Telegram, routes messages
├── start-claude.sh          # Creates new Claude tmux sessions (smart-rotate accounts)
├── send-summary.sh          # Sends formatted messages to Telegram
├── inject-prompt.sh         # Injects prompts into sessions (buffer-based)
├── notify.sh                # Send notifications
├── find-session.sh          # Search past sessions by keyword
├── watchdog.sh              # Monitor and fix stuck sessions
├── ralph-task.sh            # RALPH task management
├── ralph-worker.sh          # Autonomous task loop worker
├── ralph-status.sh          # Show RALPH worker status
├── start-lobby.sh           # Start Clawdbot lobby session
│
├── scripts/                 # Utility scripts
│   ├── auto-respawn.sh      # Context-aware session respawn with Agent Teams detection
│   ├── auto-respawn-toggle.sh # Enable/disable auto-respawn
│   ├── restart-all.sh       # Graceful restart all sessions (5 modes)
│   ├── check-context.sh     # Check context % for a session
│   └── trigger-handoff.sh   # Manual handoff trigger
│
├── lib/                     # RALPH library modules
│   ├── circuit_breaker.sh   # 3-state circuit breaker
│   ├── exit_detector.sh     # Multi-condition exit detection
│   ├── rate_limiter.sh      # API rate limiting
│   └── response_analyzer.sh # Parse RALPH_STATUS from output
│
├── templates/
│   └── SPAWN_AGENT.md       # Template for spawning agents
│
├── coordinator-claude.md    # System prompt for claude-0
├── TELEGRAM_FORMAT.md       # Message format template
├── CLAUDE.md                # Instructions for Claude agents
│
├── config.env               # Settings (poll interval, etc.)
├── .env.local               # Secrets (bot token, API keys) - gitignored
├── enabled                  # Touch to enable, rm to disable
│
├── sessions/                # Active session tracking
├── logs/                    # Runtime logs
├── watchdog-state/          # Watchdog state files
└── worker-state/            # RALPH worker state files

~/.claude/logs/tmux/         # Auto-generated tmux session logs
├── claude-0_2026-02-06-1200.log
├── claude-1_2026-02-06-1205.log
└── ...
```

## Watchdog

The watchdog monitors Claude sessions and keeps them productive.

### Features

- **Force push** watched instances every 5 minutes
- **Reminders** to ALL claude-* instances every 30 minutes
- **Auto-fix** stuck states every 30 seconds

### Stuck State Detection

| State | Detection | Fix |
|-------|-----------|-----|
| `approval_prompt` | Shows "Y/n" or numbered options | Auto-accepts |
| `plan_mode` | Shows "plan mode on" | Exits plan mode |
| `quote_stuck` | Shows `quote>` or `dquote>` | Clears input |
| `input_pending` | Shows "↵ send" | Sends Enter |
| `low_context` | Context < 15% | Restarts session |
| `dead` | No output | Restarts session |

### Circuit Breaker

The watchdog includes a RALPH-style circuit breaker:

| State | Description |
|-------|-------------|
| **Normal** | Session operating normally |
| **No Progress** | Tracking cycles without file changes |
| **OPEN** | Session halted - needs `/circuit N reset` |

Thresholds:
- 3 cycles with no progress → circuit OPEN
- 5 consecutive completion indicators without EXIT_SIGNAL → circuit OPEN

## RALPH Integration

RALPH (Recursive Autonomous Loop for Programming Help) enables autonomous task execution.

### Task File Format

Tasks are stored in `~/.claude/handoffs/<session>-task.md`:

```markdown
# Task: Implement user authentication

**Session:** claude-5
**Created:** 2026-01-22 17:30
**Status:** IN_PROGRESS

## Checklist

- [x] Create user model
- [x] Add login endpoint
- [ ] Add logout endpoint
- [ ] Write tests

## RALPH_STATUS

RALPH_STATUS:
STATUS: IN_PROGRESS
EXIT_SIGNAL: false
WORK_TYPE: feature
FILES_MODIFIED: 5
TASKS_REMAINING: 2
```

### Exit Conditions

The worker exits when ANY of these conditions are met:

1. **EXIT_SIGNAL: true** - Claude explicitly signals completion
2. **All checkboxes complete** - Task file has all `[x]` boxes
3. **Safety threshold** - 5 completion indicators without EXIT_SIGNAL
4. **Test saturation** - 3+ loops with only test work
5. **Circuit breaker OPEN** - Session stuck/no progress

### RALPH_STATUS Protocol

Claude sessions should output status blocks:

```
RALPH_STATUS:
STATUS: IN_PROGRESS|COMPLETE
EXIT_SIGNAL: true|false
WORK_TYPE: feature|bugfix|test|docs|research
FILES_MODIFIED: N
TASKS_REMAINING: N
```

**Rules:**
- `EXIT_SIGNAL: true` only when ALL work is done
- `STATUS: COMPLETE` can be used for phase completion with `EXIT_SIGNAL: false`

## Multi-Account Support

Run sessions on different Claude accounts to avoid rate limits.

### Setup Account 2

```bash
CLAUDE_CONFIG_DIR=~/.claude-account2 claude login
```

### Account Suffixes

- **Account 1:** `claude-N` (no suffix)
- **Account 2:** `claude-N-acc2`

### Rate Limit Detection

The watchdog automatically detects rate limits and can migrate sessions:
- Monitors for "You've hit your limit" messages
- Detects usage percentage warnings
- Auto-migrates at 95%+ usage (if configured)

## Input Sanitization

All Telegram input is sanitized before being injected into tmux sessions. Shell metacharacters are stripped to prevent command injection through Telegram messages.

**Sanitized characters:** `` ` `` `$` `(` `)` `|` `;` `&` `>` `<` `\`

This runs automatically in `orchestrator.sh` before any message reaches a session.

## tmux Session Logging

Every tmux session is automatically logged to disk with ANSI escape sequences stripped. Logs are searchable by any Claude instance.

### How It Works

1. A `session-created` hook in `~/.tmux.conf` starts `pipe-pane` for every new session
2. `start-claude.sh` also enables logging as defense-in-depth
3. Output flows through `tmux-log-pipe.sh` which strips ANSI codes via perl
4. Clean text is written to `~/.claude/logs/tmux/{session}_{YYYY-MM-DD-HHMM}.log`

### Log File Naming

Each session lifetime gets its own file: `{session}_{YYYY-MM-DD-HHMM}.log`

When a session is restarted, a new file is created with a new timestamp. This means you can see the full history of a session across restarts.

### Querying Logs

Use `tmux-log.sh` to search, tail, and clip logs:

```bash
# Search all sessions for a keyword
~/.claude/scripts/tmux-log.sh search "authentication"

# Search a specific session
~/.claude/scripts/tmux-log.sh search "error" --session claude-3

# Tail live output
~/.claude/scripts/tmux-log.sh tail claude-1

# Copy last 50 lines to clipboard
~/.claude/scripts/tmux-log.sh clip claude-1 50

# List all log files
~/.claude/scripts/tmux-log.sh list

# Check logging status
~/.claude/scripts/tmux-log.sh status

# Enable logging for a session that missed the hook
~/.claude/scripts/tmux-log.sh enable claude-5
```

### Log Retention

`tmux-log-cleanup.sh` deletes logs older than 7 days. Can be added to cron:

```bash
0 3 * * * ~/.claude/scripts/tmux-log-cleanup.sh
```

## Restart All Sessions

Gracefully restart all Claude sessions with handoff continuity. Handles: new Claude Code versions, config changes, mass crashes, Mac shutdown/restart.

### Usage

```bash
~/.claude/scripts/restart-all.sh [MODE] [OPTIONS]
```

### Modes

| Mode | Behavior |
|------|----------|
| `--graceful` (default) | Inject handoff request, wait, kill, restart with continuity |
| `--force` | Kill all immediately, restart with best-effort recent handoffs |
| `--shutdown` | Handoff + kill (no restart), save state file for `--resume` |
| `--resume` | Read saved state file, restart all sessions with saved handoffs |
| `--status` | Show all sessions: state, account, context %, latest handoff |

### Options

| Option | Description |
|--------|-------------|
| `--timeout <seconds>` | Override handoff wait timeout (default from config) |
| `--reason <text>` | Reason included in injected prompts and notifications |
| `--dry-run` | Show what would happen without executing |

### Examples

```bash
# Preview what would happen
restart-all.sh --dry-run

# Check session states
restart-all.sh --status

# Graceful restart for Claude Code update
restart-all.sh --reason "Claude Code update"

# Emergency restart (skip handoff wait)
restart-all.sh --force --reason "mass crash"

# Shutdown before Mac restart, resume after
restart-all.sh --shutdown --reason "Mac update"
# ... after reboot ...
restart-all.sh --resume
```

### Graceful Flow

```
1. Discover sessions (tmux list-sessions, filter claude-*, skip excluded)
2. Capture working directories while sessions alive
3. Inject handoff request to ALL workers in PARALLEL
4. 5s delay, then inject to coordinator (claude-0)
5. Wait for handoff files (poll 10s, dual validation)
6. Kill workers first, then coordinator
7. Restart coordinator FIRST, then workers (staggered 2s)
8. Inject continuation prompt from handoff
9. Re-enable tmux pipe-pane logging
10. Send Telegram + TTS notifications
```

### Key Behaviors

- **Coordinator ordering** — claude-0 is killed last and restarted first (it receives notifications from other sessions)
- **Account-aware** — sessions with `-acc2` suffix restart with `CLAUDE_CONFIG_DIR=~/.claude-account2`
- **Crashed session handling** — detects crashed sessions via pane content, skips handoff injection, still restarts
- **Agent Teams** — extends timeout to 600s if active teammates are detected
- **State file** — `--shutdown` saves session list + handoff paths to `~/.claude/restart-state.json` for later `--resume`
- **RALPH integration** — includes active task file info in continuation prompt if present
- **Excluded sessions** — respects `excluded_sessions` from `~/.claude/handoff-config.json`

## Smart Account Rotation

When starting new sessions via `start-claude.sh`, the system tracks usage per account and selects the least-used one. This spreads load across multiple Claude accounts to minimize rate limiting.

### How It Works

1. Each session's account is recorded in `sessions/` directory
2. `start-claude.sh` counts active sessions per account
3. New sessions are assigned to the account with fewer active sessions
4. Account 2 sessions get the `-acc2` suffix and `CLAUDE_CONFIG_DIR` env var

## Auto-Respawn

Sessions auto-handoff when context usage exceeds the configured threshold (default: 60%).

### Flow

1. `check-context.sh` detects context threshold exceeded
2. `auto-respawn.sh` injects handoff request into the session
3. Waits for handoff file (dual validation: filename timestamp OR file modification time)
4. Kills old session, starts fresh one in same directory
5. Injects continuation prompt extracted from handoff
6. Restarts RALPH worker if one was running
7. Notifies coordinator and Telegram

### Agent Teams Protection

If the session has active Agent Teams (detected via child process count, team lock file, or output keywords), the timeout extends to 600s and the session is asked to complete team work first.

### Configuration

Located at `~/.claude/handoff-config.json`:

```json
{
  "auto_respawn": true,
  "threshold_percent": 60,
  "handoff_wait_seconds": 300,
  "notify_orchestrator": true,
  "excluded_sessions": ["backend", "frontend"]
}
```

## How Claude Sends Summaries

When a message comes from Telegram, the orchestrator appends: `<tg>send-summary.sh</tg>`

Claude sees this and sends a summary when done:

```bash
~/.claude/telegram-orchestrator/send-summary.sh --session $(tmux display-message -p '#S') "Your summary here"
```

### Message Format

See `TELEGRAM_FORMAT.md` for the standard format:

```
{STATUS_EMOJI} <b>{Title}</b>

🎯 <b>Request:</b> What was asked
📋 <b>Result:</b>
• Key points
💡 <i>Next steps</i>
```

**Status Emojis:** ✅ Done | ⏳ Working | ❌ Failed | 💡 Info | ⚠️ Warning

## Coordinator (claude-0)

The coordinator session runs persistently and:
- Receives all non-reply messages
- Spawns worker sessions on demand
- Monitors and delegates tasks
- Injects tasks to other sessions via tmux

See `coordinator-claude.md` for the coordinator's system prompt.

## Configuration

### config.env

```bash
POLL_INTERVAL=5         # Telegram polling interval (seconds)
MAX_SESSIONS=10         # Maximum concurrent Claude sessions
```

### .env.local (secrets)

```bash
TELEGRAM_BOT_TOKEN="..."   # From BotFather
TELEGRAM_CHAT_ID="..."     # Auto-detected or manual
OPENAI_API_KEY="..."       # For Whisper voice transcription
```

### Handoff Configuration

Located at `~/.claude/handoff-config.json`:

```json
{
  "auto_respawn": true,
  "threshold_percent": 60,
  "handoff_wait_seconds": 300,
  "notify_orchestrator": true,
  "excluded_sessions": ["backend", "frontend"]
}
```

## Troubleshooting

### Check if running

```bash
ps aux | grep orchestrator
launchctl list | grep claude
```

### View logs

```bash
# Orchestrator logs
tail -f ~/.claude/telegram-orchestrator/logs/orchestrator.log

# Watchdog logs
tail -f ~/.claude/telegram-orchestrator/logs/watchdog.log

# RALPH logs
tail -f ~/.claude/telegram-orchestrator/logs/ralph-claude-5.log
```

### Restart orchestrator

```bash
launchctl stop com.claude.telegram-orchestrator
launchctl start com.claude.telegram-orchestrator
```

### Kill duplicate processes

```bash
pkill -9 -f orchestrator.sh
rm -f ~/.claude/telegram-orchestrator/.orchestrator.lock
```

### Messages not arriving

```bash
# Test Telegram API
source ~/.claude/telegram-orchestrator/.env.local
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
```

### Session stuck

```bash
# Check state
tmux capture-pane -t claude-1 -p | tail -20

# Clear input and retry
tmux send-keys -t claude-1 C-u
tmux send-keys -t claude-1 Enter

# Or use watchdog
/watchdog add claude-1
```

### Circuit breaker stuck OPEN

```bash
# Check why
cat ~/.claude/telegram-orchestrator/watchdog-state/circuits/claude-5.history

# Reset
/circuit 5 reset
# or
/ralph reset 5
```

### tmux logging not working

```bash
# Check if pipe-pane is active
tmux show-options -g | grep pipe

# Manually enable for a session
~/.claude/scripts/tmux-log.sh enable claude-1

# Check log directory
ls -la ~/.claude/logs/tmux/

# Verify hook is in tmux.conf
grep session-created ~/.tmux.conf
```

### Restart all sessions

```bash
# Check state before restart
~/.claude/scripts/restart-all.sh --status

# Dry run first
~/.claude/scripts/restart-all.sh --dry-run

# If sessions are stuck after restart
~/.claude/scripts/restart-all.sh --force --reason "cleanup"
```

### Auto-respawn not detecting handoff

```bash
# Check auto-respawn log
tail -50 ~/.claude/handoffs/auto-respawn.log

# Check handoff config
cat ~/.claude/handoff-config.json

# List recent handoff files
ls -lt ~/.claude/handoffs/ | head -10
```


