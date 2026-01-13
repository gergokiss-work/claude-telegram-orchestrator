# Watchdog

Auto-monitors Claude instances. Keeps them working and reminds them to send updates.

## Quick Start

```bash
# Start watching specific instances
watchdog.sh start claude-1 claude-3

# Reminder-only mode (no force push)
watchdog.sh start

# Stop
watchdog.sh stop

# Status
watchdog.sh status
```

## Commands

| Command | Description |
|---------|-------------|
| `start [instances...]` | Start watchdog. Empty = reminder-only mode |
| `stop` | Stop watchdog |
| `status` | Show status and instance states |
| `add <instance>` | Add instance to watch list |
| `remove <instance>` | Remove from watch list |
| `list` | List watched instances |

## Telegram Commands

```
/watchdog                         # Status
/watchdog start claude-1 claude-3 # Watch specific instances
/watchdog start                   # Reminder-only mode
/watchdog stop                    # Stop
/watchdog add claude-2            # Add to watch list
/watchdog remove claude-1         # Remove from watch list
```

## How It Works

| Action | Target | Frequency |
|--------|--------|-----------|
| Force push | Watched instances only | Every 5 min |
| TTS/Telegram reminder | ALL claude-* instances | Every 30 min |
| Auto-fix stuck states | Watched instances | Every 30 sec |

### Auto-Fix States

| State | Fix |
|-------|-----|
| approval_prompt | Auto-accepts |
| plan_mode | Exits |
| quote_stuck | Clears |
| input_pending | Sends Enter |
| low_context | Restarts session |
| dead | Restarts session |

## Files

```
watchdog.sh           # The watchdog (start/stop/status/daemon)
watchdog-state/       # State files (instances list, timing)
```

## Logs

```bash
# View watchdog output
tmux capture-pane -t watchdog -p -S -50

# Check log file
tail -50 ~/.claude/telegram-orchestrator/logs/watchdog.log
```
