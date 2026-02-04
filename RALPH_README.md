# RALPH Worker System

Sophisticated autonomous task loops for Claude sessions, integrated with the Telegram orchestrator.

## Overview

RALPH (Recursive Autonomous Loop for Programming Help) enables Claude sessions to work autonomously on complex tasks with:

- **3-State Circuit Breaker** - Prevents runaway sessions
- **Rate Limiting** - Tracks API calls per hour
- **Intelligent Exit Detection** - Multiple conditions prevent premature/stuck exits
- **Task File Integration** - Checkbox-based progress tracking

## Quick Start

### Via Telegram

```
# Start a task on session 5
/ralph start 5 Implement user authentication

# (Optional) Start worker loop for autonomous operation
/ralph loop 5 50

# Check status
/ralph status 5

# Stop worker
/ralph stop 5
```

### Via Command Line

```bash
# Start task (watchdog monitors)
~/.claude/telegram-orchestrator/ralph-task.sh claude-5 "Implement user auth"

# Start with worker loop
~/.claude/telegram-orchestrator/ralph-task.sh claude-5 --loop 50

# Check status
~/.claude/telegram-orchestrator/ralph-status.sh claude-5

# Stop worker
~/.claude/telegram-orchestrator/ralph-task.sh claude-5 --stop-worker
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    RALPH Worker Architecture                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  /ralph start N task  ─────► ralph-task.sh                      │
│                                    │                             │
│                                    ▼                             │
│                              Creates task file                   │
│                              ~/.claude/handoffs/claude-N-task.md │
│                                    │                             │
│                        ┌───────────┴───────────┐                │
│                        ▼                       ▼                │
│                   [Default Mode]         [Loop Mode]            │
│                   watchdog.sh            ralph-worker.sh        │
│                   monitors               autonomous loop         │
│                                               │                  │
│                                    ┌──────────┼──────────┐      │
│                                    ▼          ▼          ▼      │
│                              circuit_breaker  rate_limiter      │
│                              exit_detector    response_analyzer │
│                                               │                  │
│                                    ┌──────────┴──────────┐      │
│                                    ▼                     ▼      │
│                              [EXIT_SIGNAL: true]   [Continue]   │
│                              Task complete         Next loop    │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### Libraries (`lib/`)

| Library | Purpose |
|---------|---------|
| `circuit_breaker.sh` | 3-state (CLOSED→HALF_OPEN→OPEN) protection |
| `rate_limiter.sh` | Tracks calls per hour (default: 100/hr) |
| `exit_detector.sh` | Multi-condition exit detection |
| `response_analyzer.sh` | Parses RALPH_STATUS from Claude output |

### Scripts

| Script | Purpose |
|--------|---------|
| `ralph-task.sh` | Create/manage tasks, start workers |
| `ralph-worker.sh` | Autonomous loop worker |
| `ralph-status.sh` | Show worker status |

## Task File Format

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

## Circuit Breaker

The circuit breaker protects against stuck sessions:

| State | Description | Transitions |
|-------|-------------|-------------|
| **CLOSED** | Normal operation | → HALF_OPEN after 2 no-progress cycles |
| **HALF_OPEN** | Monitoring | → CLOSED on progress, → OPEN on continued failure |
| **OPEN** | Halted | Manual reset required |

### Thresholds

- `CB_NO_PROGRESS_THRESHOLD=3` - Cycles without progress before OPEN
- `CB_SAME_ERROR_THRESHOLD=5` - Repeated errors before OPEN
- `CB_OUTPUT_DECLINE_THRESHOLD=70` - % output decline before OPEN

### Reset Circuit

```bash
# Via Telegram
/ralph reset 5

# Via command line
~/.claude/telegram-orchestrator/watchdog.sh reset claude-5
```

## Exit Conditions

The worker exits when ANY of these conditions are met:

1. **EXIT_SIGNAL: true** - Claude explicitly signals completion
2. **All checkboxes complete** - Task file has all `[x]` boxes
3. **Safety threshold** - 5 completion indicators without EXIT_SIGNAL
4. **Test saturation** - 3+ loops with only test work
5. **Multiple done signals** - 2+ "done" without EXIT_SIGNAL

## RALPH_STATUS Protocol

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

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/ralph` | Show help |
| `/ralph start N task` | Start task on session N |
| `/ralph loop N [max]` | Start worker loop (default: 100) |
| `/ralph status [N]` | Show worker status |
| `/ralph stop N` | Stop worker loop |
| `/ralph cancel N` | Cancel task entirely |
| `/ralph list` | Show active tasks |
| `/ralph reset N` | Reset circuit breaker |

## Integration with Watchdog

The watchdog (`watchdog.sh`) automatically:

- Detects RALPH_STATUS in Claude output
- Respects worker-managed sessions (doesn't interfere)
- Shows circuit breaker state in status
- Archives completed task files

## State Files

Worker state is stored in `~/.claude/telegram-orchestrator/worker-state/<session>/`:

```
worker-state/
└── claude-5/
    ├── state.json       # Main worker state
    ├── circuit.json     # Circuit breaker state
    ├── rate_limit.json  # Rate limiting
    ├── response.json    # Last response analysis
    └── history.json     # Loop history
```

## Troubleshooting

### Worker not starting

```bash
# Check for existing worker
~/.claude/telegram-orchestrator/ralph-status.sh claude-5

# Check logs
tail -50 ~/.claude/telegram-orchestrator/logs/ralph-claude-5.log
```

### Circuit breaker stuck OPEN

```bash
# Check history
cat ~/.claude/telegram-orchestrator/watchdog-state/circuits/claude-5.history

# Reset
/ralph reset 5
```

### Session not responding

1. Check if worker is managing it: `/ralph status 5`
2. Check watchdog state: `/watchdog status`
3. Check circuit breaker: `/circuit 5`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RL_MAX_CALLS_PER_HOUR` | 100 | Rate limit per session |
| `CB_NO_PROGRESS_THRESHOLD` | 3 | No-progress cycles before OPEN |
| `ED_SAFETY_THRESHOLD` | 5 | Completion indicators threshold |

## References

- [RALPH Technique](https://ghuntley.com/ralph/) by Geoffrey Huntley
- [RALPH Claude Code](https://github.com/frankbria/ralph-claude-code) implementation
