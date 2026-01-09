# Telegram Orchestrator Requirements

## Vision
Control multiple Claude Code sessions from a phone via Telegram, with real-time output streaming and n8n integration for intelligent prompt processing.

## Architecture

```
┌─────────────────┐
│ Telegram (phone)│
│ - Text messages │
│ - Voice messages│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│      n8n        │
│ - Transcription │
│ - Prompt agent  │
│ - Message router│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Mac Daemon     │
│ - Session mgmt  │
│ - tmux control  │
│ - Output stream │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Claude Code    │
│ (tmux sessions) │
└─────────────────┘
```

## Functional Requirements

### FR1: Session Management
- FR1.1: Create new Claude Code session via `/new [prompt]`
- FR1.2: List active sessions via `/status`
- FR1.3: Kill session via `/kill <number>`
- FR1.4: Maximum 5 concurrent sessions
- FR1.5: Sessions run in tmux for persistence

### FR2: Message Routing
- FR2.1: Reply to a Telegram message → routes to the session that sent it
- FR2.2: `/1 message` → routes to session 1
- FR2.3: `/1 <number>` → selects menu option in session 1
- FR2.4: Plain text → routes to most recent active session
- FR2.5: Track which session sent which Telegram message (for reply routing)

### FR3: Real-Time Output
- FR3.1: Stream Claude's text responses to Telegram as they complete
- FR3.2: Notify immediately when Claude asks a question
- FR3.3: Notify when Claude requests permissions
- FR3.4: Notify on task completion
- FR3.5: Notify on errors
- FR3.6: **DO NOT** send tool call details (Bash, Read, Edit, etc.)
- FR3.7: **DO NOT** send terminal UI chrome (status bars, box chars)

### FR4: n8n Integration
- FR4.1: Receive commands from n8n webhook (not direct Telegram polling)
- FR4.2: Send output to n8n webhook (not direct Telegram API)
- FR4.3: Support message metadata (session ID, timestamp, type)
- FR4.4: Support voice message transcription via n8n
- FR4.5: Support prompt enhancement agent in n8n before sending to Claude

### FR5: TTS Integration
- FR5.1: Toggle TTS via `/tts` command
- FR5.2: Write summaries to `~/.claude/tts/summary.txt`

## Non-Functional Requirements

### NFR1: Latency
- NFR1.1: < 2 seconds from Claude output to Telegram notification
- NFR1.2: Polling interval configurable (default 5s for commands)

### NFR2: Reliability
- NFR2.1: Monitor process should not crash on malformed output
- NFR2.2: Auto-restart on failure via LaunchAgent
- NFR2.3: Graceful handling of network errors

### NFR3: Message Quality
- NFR3.1: No duplicate notifications
- NFR3.2: No stale/old content
- NFR3.3: Clean, readable text (no terminal escape codes)
- NFR3.4: Truncate long messages (Telegram 4096 char limit)

### NFR4: Security
- NFR4.1: Only respond to authorized chat ID
- NFR4.2: Bot token stored in config, not in code
- NFR4.3: Sessions run with appropriate permissions

## Current Limitations (to be solved)

1. **One message behind**: Terminal scraping captures old output, not current
2. **Polling delay**: 5s poll interval adds latency
3. **No streaming**: Can't stream output, only batch when "done"
4. **Direct Telegram**: Bypasses n8n, can't add agent processing

## Proposed Solutions

### Option A: Claude Code Hooks
Use Claude Code's hook system to push output events instead of polling.
- Pro: Native integration, real-time
- Con: Limited hook capabilities, may not expose output

### Option B: stdout Redirection
Redirect Claude Code output to a streaming processor.
- Pro: Real-time streaming possible
- Con: Complex, may break terminal interaction

### Option C: MCP Server
Create an MCP server that Claude calls to send messages.
- Pro: Clean integration, Claude controls when to notify
- Con: Requires Claude to explicitly call it

### Option D: API Instead of CLI
Use Claude API directly instead of Claude Code CLI.
- Pro: Full control, real-time streaming
- Con: Lose Claude Code features (tools, file access)

## File Structure

```
~/.claude/telegram-orchestrator/
├── config.env           # Bot token, chat ID, n8n URLs
├── orchestrator.sh      # Main daemon (receive commands)
├── session-monitor.sh   # Per-session output monitor
├── start-claude.sh      # Session launcher
├── notify.sh            # Send to n8n/Telegram
├── tg                    # Terminal helper command
├── sessions/            # Session metadata
│   ├── claude-1         # Session 1 info (working dir, start time)
│   └── claude-1.monitor.pid
└── logs/
    ├── orchestrator.log
    └── monitor-*.log
```

## Commands Reference

| Command | Description |
|---------|-------------|
| `/new [prompt]` | Start new session, optionally with initial prompt |
| `/status` | List all active sessions |
| `/kill <n>` | Kill session n |
| `/tts` | Toggle text-to-speech |
| `/1 message` | Send message to session 1 |
| `/1 <number>` | Select menu option in session 1 |
| Reply to msg | Route to original session |
| Plain text | Route to most recent session |
