# TTS System v2.0 for Claude Code

Text-to-speech summaries for Claude Code sessions - **multi-instance safe**.

## Quick Start

```bash
# Toggle TTS on/off
/tts

# Or explicitly
/tts on
/tts off
/tts status
```

## How It Works

### Writing Summaries (Claude instances)

When TTS is enabled, write summaries using session-aware filenames:

```bash
# Option 1: Use the helper script (recommended)
~/.claude/scripts/tts-write.sh "Your summary here."

# Option 2: Manual with session name
SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "main")
echo "Summary here." > ~/.claude/tts/queue/$(date +%s%N | cut -c1-13)-${SESSION}-$$.txt
```

**Filename format:** `TIMESTAMP-SESSION-PID.txt`
- Timestamp in milliseconds ensures order
- Session name identifies source (claude-0, claude-1, etc.)
- PID ensures uniqueness within session

### Reading Summaries (Hook)

The reader (`tts-reader.sh`) is triggered on Claude stop:

1. Waits for lock (instead of exiting)
2. Reads ALL pending files sequentially by timestamp
3. Each file is spoken and removed
4. Lock released when done

**Key improvement:** Multiple instances queue their summaries, and they're read **one at a time in order** - no more simultaneous speaking!

## File Structure

```
~/.claude/tts/
├── enabled          # Touch to enable, rm to disable
├── reading.lock     # Prevents concurrent reads
├── reader.log       # Debug log
├── queue/           # Summary files waiting to be read
│   ├── 1704567890123-claude-0-12345.txt
│   ├── 1704567891456-claude-1-12346.txt
│   └── ...
└── README.md
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_TTS_VOICE` | `Daniel` | macOS voice name |
| `CLAUDE_TTS_RATE` | `200` | Words per minute |

Available voices: `say -v ?`

## Multi-Instance Behavior (v2.0)

| Scenario | Behavior |
|----------|----------|
| Two instances finish simultaneously | Both queue summaries, read sequentially |
| Lock held by another reader | Waits up to 60s for lock |
| Stale lock (crashed process) | Auto-cleaned after 120s |
| Multiple files in queue | All read in timestamp order |

### Example Flow

```
10:00:00.100 - claude-1 finishes, writes summary, triggers reader
10:00:00.150 - claude-3 finishes, writes summary, triggers reader
10:00:00.200 - Reader 1 gets lock, starts reading claude-1's summary
10:00:00.200 - Reader 2 waits for lock
10:00:02.000 - Reader 1 finishes claude-1, reads claude-3's summary
10:00:04.000 - Reader 1 done, releases lock
10:00:04.001 - Reader 2 gets lock, queue empty, exits
```

## Troubleshooting

**TTS not speaking:**
```bash
# Check if enabled
ls ~/.claude/tts/enabled

# Check queue
ls -la ~/.claude/tts/queue/

# Check reader log
tail -20 ~/.claude/tts/reader.log

# Check for stale lock
cat ~/.claude/tts/reading.lock
```

**Clear stuck state:**
```bash
rm -f ~/.claude/tts/reading.lock
rm -f ~/.claude/tts/queue/*.txt
```

**Test manually:**
```bash
~/.claude/scripts/tts-write.sh "Test message from manual run"
~/.claude/scripts/tts-reader.sh
```

## Related Files

- `~/.claude/scripts/tts-toggle.sh` - Toggle TTS on/off
- `~/.claude/scripts/tts-reader.sh` - Read and speak summaries (v2.0)
- `~/.claude/scripts/tts-write.sh` - Write summary with session name (NEW)
- `~/.claude/commands/tts.md` - `/tts` command definition
