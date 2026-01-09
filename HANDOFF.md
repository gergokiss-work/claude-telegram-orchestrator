# Telegram Orchestrator - Handoff Summary

**Date:** 2026-01-09 12:00

## Current System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        TELEGRAM                                  │
│  User sends voice/text message                                  │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                   orchestrator.sh                                │
│  - Polls Telegram API every 5s                                  │
│  - Voice messages → transcribe.sh (Whisper) → text              │
│  - Appends [TELEGRAM] instruction to every message              │
│  - Injects to Claude via tmux load-buffer (reliable)            │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Claude Session (tmux)                          │
│  - Receives message + instruction                               │
│  - Does the work                                                │
│  - Calls send-summary.sh "summary" when done                    │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                   send-summary.sh                                │
│  - Sends immediately to Telegram via API                        │
│  - Detects session name from tmux (claude-1, claude-2, etc)     │
│  - Tags message with [claude-X]                                 │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                        TELEGRAM                                  │
│  User receives [claude-1] summary                               │
│  Can reply to route to specific session                         │
└─────────────────────────────────────────────────────────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| `orchestrator.sh` | Main daemon - polls Telegram, injects messages to Claude |
| `send-summary.sh` | **NEW** - Sends summary to Telegram immediately |
| `notify.sh` | Sends system notifications (errors, status, etc) |
| `start-claude.sh` | Starts new Claude session in tmux |
| `src/voice/transcribe.sh` | Whisper API transcription for voice messages |
| `telegram-sender.sh` | Queue-based sender (Stop hook only - legacy) |

## Changes Made (2026-01-09)

### 1. Removed /1 /2 /3 Commands
- User now uses Telegram reply feature to route to specific sessions
- Removed from `orchestrator.sh` (command parsing)
- Removed from Telegram bot menu via API
- Removed `select_option()` function (no longer needed)

### 2. Disabled Session Monitors
- Session monitors scraped terminal output → sent `[claude-X] Update` messages
- User only wants queue-based summaries from Claude
- Killed all running monitors
- Disabled auto-start in `start-claude.sh`

### 3. Fixed Voice Message Notifications
- Removed "🎤 Transcribing voice message..." notification
- Removed "🎤 [transcription]" notification
- Voice messages now process silently, user only gets Claude's response

### 4. Created send-summary.sh (Immediate Send)
- **Problem:** Old queue system only sent on Stop hook (session end)
- **Solution:** New script sends immediately via Telegram API
- Detects tmux session name for proper `[claude-X]` tagging

### 5. Fixed Long Message Injection
- **Problem:** Long voice transcriptions pasted but Enter not pressed
- **Solution:** Changed from `tmux send-keys` to `tmux load-buffer` + `paste-buffer`
- More reliable for long text

### 6. Auto-Append Summary Instruction
- Every message from Telegram gets instruction appended:
  ```
  [TELEGRAM] When done, send summary: ~/.claude/telegram-orchestrator/send-summary.sh "your summary here"
  ```
- Ensures Claude always sends feedback, even without CLAUDE.md

### 7. Updated Working State Detection
- Added "Noodling", "Brewing", "Scurrying" to `is_working()` patterns
- Added permission menu detection to `is_at_prompt()`
- (Only relevant if monitors re-enabled)

## Bot Commands

| Command | Description |
|---------|-------------|
| `/status` | List active Claude sessions |
| `/new` | Start new Claude session |
| `/kill <n>` | Stop session n (e.g., `/kill 2`) |
| `/tts` | Toggle TTS read-aloud |

## How Replies Work

1. Claude sends message tagged `[claude-1]`
2. User replies to that message in Telegram
3. Orchestrator detects `[claude-1]` in replied message
4. Routes user's reply to `claude-1` session

## Running Processes

| Process | Purpose | Auto-start |
|---------|---------|------------|
| `orchestrator.sh` | Polls Telegram, injects messages | LaunchAgent |
| Session monitors | **DISABLED** | No |

## LaunchAgent

Location: `~/Library/LaunchAgents/com.claude.telegram-orchestrator.plist`

```bash
# Check status
launchctl list | grep claude

# Restart
launchctl stop com.claude.telegram-orchestrator
launchctl start com.claude.telegram-orchestrator
```

## Troubleshooting

### No response from Claude
1. Check orchestrator running: `ps aux | grep orchestrator`
2. Check logs: `tail -50 ~/.claude/telegram-orchestrator/logs/orchestrator.log`
3. Check tmux session exists: `tmux list-sessions`

### Wrong session tagged
- Reply feature extracts `[claude-X]` from replied message
- If no reply, goes to most recent session

### Long messages not submitting
- Fixed with `tmux load-buffer` approach
- If still failing, check `inject_input()` in orchestrator.sh

## GitHub Repo

https://github.com/gergokiss-work/claude-telegram-orchestrator
