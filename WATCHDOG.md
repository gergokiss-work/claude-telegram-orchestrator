# Watchdog System

Auto-monitors Claude instances and keeps them working. Prevents stuck states and ensures continuous progress.

## Quick Start

```bash
# From Telegram
/watchdog status              # Check status
/watchdog start claude-1      # Start watching claude-1
/watchdog stop                # Stop watchdog

# From CLI
~/.claude/telegram-orchestrator/watchdog-control.sh status
```

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/watchdog` | Show status |
| `/watchdog status` | Show status (same as above) |
| `/watchdog start` | Start with current config |
| `/watchdog start claude-1 claude-3` | Watch only specific instances |
| `/watchdog stop` | Stop watchdog completely |
| `/watchdog pause` | Pause (preserves config for later) |
| `/watchdog add claude-2` | Add instance to watch list |
| `/watchdog remove claude-3` | Remove from watch list |
| `/watchdog list` | List watched instances |

## CLI Commands

```bash
# Control script
~/.claude/telegram-orchestrator/watchdog-control.sh <command>

# Commands
start [instances...]   # Start watching (optionally set which instances)
stop                   # Stop watchdog completely
pause                  # Pause watchdog (preserves config)
status                 # Show watchdog status and instance states
add <instance>         # Add instance to watch list
remove <instance>      # Remove instance from watch list
list                   # List watched instances
help                   # Show help
```

## How It Works

1. **Runs in tmux session** named `watchdog`
2. **Checks watched instances every 30 seconds**
3. **Force-pushes watched instances every 5 minutes** to keep them working
4. **Sends TTS/Telegram reminder to ALL instances every 30 minutes** (not just watched)
5. **Auto-fixes stuck states**:
   - Approval prompts → accepts
   - Plan mode → exits
   - Stuck input → clears
   - Low context → compacts
   - Dead session → restarts

### Two Types of Actions

| Action | Target | Frequency | Purpose |
|--------|--------|-----------|---------|
| Force push | Watched instances only | Every 5 min | Keep working on autonomous tasks |
| TTS/Telegram reminder | ALL claude-* instances | Every 30 min | Remind to send updates |

## Configuration

Watch list stored in: `~/.claude/telegram-orchestrator/watchdog-config.txt`

```
# One instance per line
claude-1
claude-3
claude-5
```

Edit directly or use `add`/`remove` commands.

## Architecture

```
watchdog (tmux session)
   └── night-watchdog.sh (main loop)
         ├── Checks every 30s
         ├── Force push every 5min
         └── Reports every 30min

watchdog-control.sh
   └── CLI/Telegram interface to manage watchdog
```

## Status Icons

| Icon | Meaning |
|------|---------|
| 🟢 | Running |
| 🔴 | Stopped |
| ⏸️ | Paused (config preserved) |

## Instance States (detected)

| State | Meaning | Auto-Fix |
|-------|---------|----------|
| working | Actively processing | - |
| idle | Ready for input | Force push |
| approval_prompt | Waiting for Y/N | Auto-accepts |
| plan_mode | In planning | Auto-exits |
| quote_stuck | Input has quote | Clears |
| input_pending | Has unsent input | Sends Enter |
| low_context | Context warning | Compacts |
| dead | Not responding | Restarts |

## Files

| File | Purpose |
|------|---------|
| `night-watchdog.sh` | Main watchdog loop |
| `watchdog-control.sh` | Control interface |
| `watchdog-config.txt` | Watch list |
| `watchdog-state/` | State tracking (timestamps) |
| `watchdog.pid` | PID file |
| `watchdog.paused` | Pause marker |

## Logs

```bash
# View watchdog output
tmux capture-pane -t watchdog -p -S -50

# Check recent actions
grep "Force push" ~/.claude/telegram-orchestrator/logs/orchestrator.log
```

## Troubleshooting

**Watchdog not starting:**
```bash
# Check if already running
tmux has-session -t watchdog && echo "Already running"

# Kill and restart
tmux kill-session -t watchdog
~/.claude/telegram-orchestrator/watchdog-control.sh start
```

**Instance not being watched:**
```bash
# Check config
cat ~/.claude/telegram-orchestrator/watchdog-config.txt

# Add instance
~/.claude/telegram-orchestrator/watchdog-control.sh add claude-2
```

**Watchdog confusing instances:**
The watchdog sends generic "keep working" messages. If instances are doing very different tasks, consider watching them separately or not at all.

## Best Practices

1. **Only watch instances doing autonomous work** - Don't watch instances you're actively using
2. **Use specific instance lists** - `/watchdog start claude-1 claude-3` instead of all
3. **Stop when interacting manually** - `/watchdog stop` before sending manual tasks
4. **Check status first** - `/watchdog` to see what's being watched
