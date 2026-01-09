# Claude Telegram Orchestrator v2 - Enhanced Architecture Plan

## Executive Summary

Transform the current bash-based Telegram orchestrator into a production-grade system with:
- **Voice message support** via Whisper transcription
- **AI prompt enhancement** to expand terse voice/text commands
- **AI output reformatting** to clean Claude's terminal output for mobile
- **Comprehensive logging** with SQLite database for all prompts/outputs
- **Multi-instance awareness** with clear session distinction

---

## Current State Analysis

### What Exists
```
~/.claude/telegram-orchestrator/
├── orchestrator.sh      # Polls Telegram, routes messages to tmux
├── session-monitor.sh   # Watches tmux pane, sends notifications
├── start-claude.sh      # Creates new tmux + Claude session
├── notify.sh            # Sends messages to Telegram
├── config.env           # Bot token, chat ID, settings
└── tg                   # Terminal helper command
```

### Current Limitations
1. **No voice support** - Only handles `.message.text`, ignores `.message.voice`
2. **No AI processing** - Raw input goes directly to Claude, raw output to Telegram
3. **No logging** - Messages are fire-and-forget, no history
4. **Basic output filtering** - Regex-based, misses edge cases
5. **Single-language assumption** - No language detection

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           TELEGRAM (Your Phone)                              │
│                                                                              │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                     │
│   │ Text Msg    │    │ Voice Msg   │    │ Command     │                     │
│   │ "fix bug"   │    │ 🎤 (audio)  │    │ /status     │                     │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                     │
└──────────┼──────────────────┼──────────────────┼────────────────────────────┘
           │                  │                  │
           │    HTTPS (Telegram Bot API - Polling)
           │                  │                  │
           ▼                  ▼                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              YOUR MAC                                        │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                     ORCHESTRATOR (orchestrator.sh)                     │  │
│  │                                                                        │  │
│  │  • Polls Telegram every 5s                                            │  │
│  │  • Detects message type (text/voice/command)                          │  │
│  │  • Routes to appropriate handler                                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                    │                  │                  │                   │
│           ┌───────┴───────┐          │          ┌───────┴───────┐           │
│           ▼               │          ▼          │               ▼           │
│  ┌─────────────────┐     │  ┌─────────────┐    │    ┌─────────────────┐    │
│  │ VOICE PIPELINE  │     │  │  COMMANDS   │    │    │  TEXT INPUT     │    │
│  │                 │     │  │             │    │    │                 │    │
│  │ 1. Download OGA │     │  │ /status     │    │    │ Direct to       │    │
│  │ 2. Convert WAV  │     │  │ /new        │    │    │ Enhancement     │    │
│  │ 3. Whisper API  │     │  │ /kill       │    │    │                 │    │
│  │ 4. Get text     │     │  │ /tts        │    │    │                 │    │
│  └────────┬────────┘     │  └─────────────┘    │    └────────┬────────┘    │
│           │              │                     │             │              │
│           └──────────────┴─────────────────────┴─────────────┘              │
│                                    │                                         │
│                                    ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    PROMPT ENHANCER (ai/enhance.sh)                     │  │
│  │                                                                        │  │
│  │  Input: "fix the bug in login"                                        │  │
│  │                                                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │ Claude Haiku / GPT-4o-mini / Groq                               │  │  │
│  │  │                                                                  │  │  │
│  │  │ System: "You enhance terse commands for Claude Code CLI.        │  │  │
│  │  │          Fix typos, expand abbreviations, add context.          │  │  │
│  │  │          Keep intent exact. Be concise but unambiguous."        │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                        │  │
│  │  Output: "Please investigate and fix the bug in the login            │  │
│  │           functionality. Check authentication flow and error          │  │
│  │           handling. Run tests after fixing."                          │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                                    ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         LOGGING (db/log.sh)                            │  │
│  │                                                                        │  │
│  │  SQLite: INSERT INTO messages (session_id, direction, raw, processed) │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                                    ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    TMUX SESSION INJECTION                              │  │
│  │                                                                        │  │
│  │  tmux send-keys -t claude-1 "Enhanced prompt here"                    │  │
│  │  tmux send-keys -t claude-1 -H 0d                                     │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│           ┌────────────────────────┴────────────────────────┐               │
│           ▼                                                  ▼               │
│  ┌─────────────────┐                                ┌─────────────────┐     │
│  │   CLAUDE-1      │                                │   CLAUDE-2      │     │
│  │   (tmux)        │                                │   (tmux)        │     │
│  │                 │                                │                 │     │
│  │  Claude Code    │                                │  Claude Code    │     │
│  │  --dangerously  │                                │  --dangerously  │     │
│  └────────┬────────┘                                └────────┬────────┘     │
│           │                                                  │               │
│           └────────────────────────┬─────────────────────────┘               │
│                                    │                                         │
│                                    ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                SESSION MONITOR (session-monitor.sh)                    │  │
│  │                                                                        │  │
│  │  • Captures tmux pane every 2s                                        │  │
│  │  • Detects idle state (Claude waiting for input)                      │  │
│  │  • Extracts response text                                             │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                                    ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                  OUTPUT REFORMATTER (ai/reformat.sh)                   │  │
│  │                                                                        │  │
│  │  Input: Raw terminal output (2000+ chars with ANSI, tool calls, etc.) │  │
│  │                                                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │ Step 1: Strip ANSI codes                                        │  │  │
│  │  │ Step 2: Remove tool call noise (⏺ Bash, Running..., etc.)      │  │  │
│  │  │ Step 3: If > 2000 chars → Summarize with LLM                   │  │  │
│  │  │ Step 4: Format for mobile (clean markdown)                      │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                        │  │
│  │  Output: Clean, concise message for Telegram                          │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                                    ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         LOGGING (db/log.sh)                            │  │
│  │                                                                        │  │
│  │  SQLite: INSERT INTO messages (session_id, direction, raw, processed) │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                    │                                         │
│                                    ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                       NOTIFY (notify.sh)                               │  │
│  │                                                                        │  │
│  │  • Add session tag [claude-1]                                         │  │
│  │  • Add status emoji (📝 update, ❓ question, ✅ complete)             │  │
│  │  • Chunk if > 4096 chars                                              │  │
│  │  • POST to Telegram API                                               │  │
│  │                                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ HTTPS (Telegram sendMessage)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           TELEGRAM (Your Phone)                              │
│                                                                              │
│   📱 Receive formatted notification                                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Deep Dives

### 1. Voice Pipeline

#### Flow
```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Telegram    │     │   Download   │     │   Convert    │     │  Whisper     │
│  Voice Msg   │────▶│   OGA File   │────▶│   to WAV     │────▶│  Transcribe  │
│  (file_id)   │     │   (curl)     │     │   (ffmpeg)   │     │   (API)      │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
                                                                      │
                                                                      ▼
                                                               ┌──────────────┐
                                                               │   Text       │
                                                               │   Output     │
                                                               └──────────────┘
```

#### Implementation: `src/voice/process.sh`
```bash
#!/bin/bash
# Process a Telegram voice message

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/config.env"

FILE_ID="$1"
MESSAGE_ID="$2"

TEMP_DIR="$SCRIPT_DIR/../../data/temp"
mkdir -p "$TEMP_DIR"

# Step 1: Get file path from Telegram
file_info=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${FILE_ID}")
file_path=$(echo "$file_info" | jq -r '.result.file_path')

if [[ -z "$file_path" || "$file_path" == "null" ]]; then
    echo "ERROR: Could not get file path"
    exit 1
fi

# Step 2: Download the OGA file
oga_file="$TEMP_DIR/voice_${MESSAGE_ID}.oga"
curl -s "https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${file_path}" -o "$oga_file"

# Step 3: Convert to WAV (Whisper prefers 16kHz mono WAV)
wav_file="$TEMP_DIR/voice_${MESSAGE_ID}.wav"
ffmpeg -i "$oga_file" -ar 16000 -ac 1 -y "$wav_file" 2>/dev/null

# Step 4: Transcribe with Whisper
transcription=$("$SCRIPT_DIR/transcribe.sh" "$wav_file")

# Step 5: Cleanup
rm -f "$oga_file" "$wav_file"

# Output the transcription
echo "$transcription"
```

#### Whisper Provider Options

| Provider | Latency | Cost | Setup |
|----------|---------|------|-------|
| OpenAI Whisper API | ~2-5s | $0.006/min | API key only |
| Groq Whisper | ~0.5-1s | $0.0001/min | API key only |
| Local whisper.cpp | ~1-3s | Free | brew install whisper-cpp |

**Recommendation**: Start with Groq (fastest, cheapest), fallback to OpenAI.

#### Implementation: `src/voice/transcribe.sh`
```bash
#!/bin/bash
# Transcribe audio file using configured provider

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/config.env"

AUDIO_FILE="$1"
PROVIDER="${WHISPER_PROVIDER:-groq}"  # groq, openai, local

case "$PROVIDER" in
    groq)
        curl -s "https://api.groq.com/openai/v1/audio/transcriptions" \
            -H "Authorization: Bearer $GROQ_API_KEY" \
            -F "file=@$AUDIO_FILE" \
            -F "model=whisper-large-v3" \
            -F "language=${WHISPER_LANGUAGE:-}" | jq -r '.text'
        ;;
    openai)
        curl -s "https://api.openai.com/v1/audio/transcriptions" \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -F "file=@$AUDIO_FILE" \
            -F "model=whisper-1" \
            -F "language=${WHISPER_LANGUAGE:-}" | jq -r '.text'
        ;;
    local)
        whisper-cpp -m "$WHISPER_MODEL_PATH" -f "$AUDIO_FILE" --no-timestamps 2>/dev/null
        ;;
esac
```

---

### 2. Prompt Enhancement

#### Purpose
Voice-to-text and quick mobile typing produce terse, potentially error-filled input:
- "chk the logs fr errors" → typos
- "do the thing we discussed" → vague
- "implementáld a feature-t" → mixed language

The enhancer expands this into clear, unambiguous prompts.

#### Enhancement Modes

| Mode | When to Use | Example |
|------|-------------|---------|
| **Expand** | Terse commands | "fix bug" → "Please investigate and fix the bug. Check error logs, identify root cause, implement fix, and verify with tests." |
| **Clarify** | Vague references | "do the auth thing" → "Implement the authentication feature we discussed. [Context from history if available]" |
| **Fix** | Typos/STT errors | "chk th logs" → "Check the logs" |
| **Translate** | Mixed language | "implementáld a login-t" → "Implement the login functionality" |
| **Bypass** | Commands | "/status", "/kill 2" → Pass through unchanged |

#### Implementation: `src/ai/enhance.sh`
```bash
#!/bin/bash
# Enhance a user prompt for Claude Code

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/config.env"

RAW_INPUT="$1"
SESSION_NAME="$2"

# Bypass commands
if [[ "$RAW_INPUT" =~ ^/ ]]; then
    echo "$RAW_INPUT"
    exit 0
fi

# Bypass if enhancement is disabled
if [[ "$ENHANCE_ENABLED" != "true" ]]; then
    echo "$RAW_INPUT"
    exit 0
fi

# Bypass if input is already long/detailed (>100 chars)
if [[ ${#RAW_INPUT} -gt 100 ]]; then
    echo "$RAW_INPUT"
    exit 0
fi

# Get recent context (last 3 exchanges) for this session
CONTEXT=$("$SCRIPT_DIR/../db/get-context.sh" "$SESSION_NAME" 3)

# Build the enhancement prompt
SYSTEM_PROMPT="You are a prompt enhancer for Claude Code CLI.

Your job is to expand terse user commands into clear, detailed prompts.

Rules:
1. PRESERVE the user's exact intent - never add features they didn't ask for
2. Fix obvious typos and speech-to-text errors
3. Expand abbreviations and vague references
4. Keep output concise but unambiguous
5. If input is already clear, return it unchanged
6. Output ONLY the enhanced prompt, nothing else
7. Output in the same language as the input (or English if mixed)

Recent conversation context:
$CONTEXT"

# Call the enhancement LLM
case "$ENHANCE_PROVIDER" in
    anthropic)
        result=$(curl -s "https://api.anthropic.com/v1/messages" \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "{
                \"model\": \"${ENHANCE_MODEL:-claude-3-haiku-20240307}\",
                \"max_tokens\": 500,
                \"system\": $(echo "$SYSTEM_PROMPT" | jq -Rs .),
                \"messages\": [{\"role\": \"user\", \"content\": $(echo "$RAW_INPUT" | jq -Rs .)}]
            }" | jq -r '.content[0].text')
        ;;
    openai)
        result=$(curl -s "https://api.openai.com/v1/chat/completions" \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${ENHANCE_MODEL:-gpt-4o-mini}\",
                \"max_tokens\": 500,
                \"messages\": [
                    {\"role\": \"system\", \"content\": $(echo "$SYSTEM_PROMPT" | jq -Rs .)},
                    {\"role\": \"user\", \"content\": $(echo "$RAW_INPUT" | jq -Rs .)}
                ]
            }" | jq -r '.choices[0].message.content')
        ;;
    groq)
        result=$(curl -s "https://api.groq.com/openai/v1/chat/completions" \
            -H "Authorization: Bearer $GROQ_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${ENHANCE_MODEL:-llama-3.1-8b-instant}\",
                \"max_tokens\": 500,
                \"messages\": [
                    {\"role\": \"system\", \"content\": $(echo "$SYSTEM_PROMPT" | jq -Rs .)},
                    {\"role\": \"user\", \"content\": $(echo "$RAW_INPUT" | jq -Rs .)}
                ]
            }" | jq -r '.choices[0].message.content')
        ;;
esac

# Fallback to original if enhancement fails
if [[ -z "$result" || "$result" == "null" ]]; then
    echo "$RAW_INPUT"
else
    echo "$result"
fi
```

---

### 3. Output Reformatting

#### The Problem
Claude Code terminal output is noisy for mobile:
```
⏺ Read src/auth/login.ts
  Running...
  Completed
⏺ Bash npm test
  Running...
  > test-project@1.0.0 test
  > jest

  PASS src/auth/login.test.ts
  ✓ should authenticate valid user (15ms)
  ✓ should reject invalid password (8ms)

  Test Suites: 1 passed, 1 total
  Tests:       2 passed, 2 total

I've fixed the authentication bug. The issue was in the password validation
logic - it was comparing hashed passwords incorrectly. I've also added
comprehensive tests to prevent regression.

>
```

#### Desired Output
```
Fixed the auth bug - password validation was comparing hashes incorrectly.
Added 2 tests, all passing.
```

#### Reformatting Pipeline

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         OUTPUT REFORMATTING PIPELINE                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  RAW OUTPUT (from tmux capture-pane)                                         │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STAGE 1: Strip ANSI escape codes                                    │    │
│  │                                                                      │    │
│  │ sed 's/\x1b\[[0-9;]*m//g'                                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STAGE 2: Remove tool call noise (regex)                             │    │
│  │                                                                      │    │
│  │ Filter out lines matching:                                          │    │
│  │ - ^⏺ (Bash|Read|Edit|Write|Grep|Glob|Task|WebFetch|TodoWrite)      │    │
│  │ - ^(Running\.\.\.|Completed|Output)                                 │    │
│  │ - Box drawing characters (╭╰│─├┤)                                   │    │
│  │ - Progress indicators, token counts                                 │    │
│  │ - Empty lines in sequence                                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STAGE 3: Length check                                               │    │
│  │                                                                      │    │
│  │ if len > 2000 chars:                                                │    │
│  │   → Go to STAGE 4 (LLM summarization)                               │    │
│  │ else:                                                                │    │
│  │   → Go to STAGE 5 (formatting)                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ├─────────────────────────────────────────┐                           │
│       │ Long (>2000 chars)                      │ Short                      │
│       ▼                                         │                            │
│  ┌─────────────────────────────────────────┐   │                            │
│  │ STAGE 4: LLM Summarization              │   │                            │
│  │                                          │   │                            │
│  │ System: "Summarize this Claude Code     │   │                            │
│  │ output for mobile Telegram. Extract     │   │                            │
│  │ key information: what was done, any     │   │                            │
│  │ errors, final status. Max 500 chars."   │   │                            │
│  └───────────────────┬─────────────────────┘   │                            │
│                      │                          │                            │
│                      └──────────────────────────┤                            │
│                                                 │                            │
│       ┌─────────────────────────────────────────┘                            │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STAGE 5: Format for Telegram                                        │    │
│  │                                                                      │    │
│  │ - Ensure clean markdown (escape special chars)                      │    │
│  │ - Preserve code blocks if present                                   │    │
│  │ - Remove trailing whitespace                                        │    │
│  │ - Ensure ends with newline                                          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ▼                                                                      │
│  FORMATTED OUTPUT (ready for Telegram)                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Implementation: `src/ai/reformat.sh`
```bash
#!/bin/bash
# Reformat Claude output for Telegram

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/config.env"

RAW_OUTPUT="$1"

# Stage 1: Strip ANSI
cleaned=$(echo "$RAW_OUTPUT" | sed 's/\x1b\[[0-9;]*m//g')

# Stage 2: Remove tool noise
cleaned=$(echo "$cleaned" | \
    grep -vE '^\s*$' | \
    grep -vE '^(╭|╰|│|─|├|┤|┬|┴|┼)' | \
    grep -vE '^⏺ (Bash|Read|Edit|Write|Grep|Glob|Task|Update|WebFetch|WebSearch|TodoWrite)' | \
    grep -vE '^\s*(Running|Completed|Output|Marinating|Thinking)' | \
    grep -vE 'tokens remaining|bypass permissions|esc to interrupt' | \
    grep -vE '^\s*>\s*$' | \
    cat -s)  # Squeeze multiple blank lines

# Stage 3: Length check
char_count=${#cleaned}

if [[ $char_count -gt ${REFORMAT_THRESHOLD:-2000} && "$REFORMAT_ENABLED" == "true" ]]; then
    # Stage 4: LLM Summarization
    SYSTEM_PROMPT="Summarize this Claude Code CLI output for mobile Telegram.

Rules:
1. Extract ONLY the essential information
2. What was done? Any errors? Final status?
3. Maximum 500 characters
4. Use clean markdown formatting
5. Preserve important code snippets if short
6. Be direct and concise"

    case "$REFORMAT_PROVIDER" in
        anthropic)
            cleaned=$(curl -s "https://api.anthropic.com/v1/messages" \
                -H "x-api-key: $ANTHROPIC_API_KEY" \
                -H "anthropic-version: 2023-06-01" \
                -H "content-type: application/json" \
                -d "{
                    \"model\": \"${REFORMAT_MODEL:-claude-3-haiku-20240307}\",
                    \"max_tokens\": 600,
                    \"system\": $(echo "$SYSTEM_PROMPT" | jq -Rs .),
                    \"messages\": [{\"role\": \"user\", \"content\": $(echo "$cleaned" | jq -Rs .)}]
                }" | jq -r '.content[0].text')
            ;;
        # ... other providers similar to enhance.sh
    esac
fi

# Stage 5: Final formatting
echo "$cleaned" | sed 's/[[:space:]]*$//'  # Trim trailing whitespace
```

---

### 4. Logging System

#### Database Schema

```sql
-- File: src/db/schema.sql

-- Sessions table
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_name TEXT UNIQUE NOT NULL,      -- claude-1, claude-2, etc.
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    ended_at DATETIME,
    working_dir TEXT,
    initial_prompt TEXT,
    status TEXT DEFAULT 'active',           -- active, stopped, killed

    -- Indexes
    UNIQUE(session_name)
);

CREATE INDEX idx_sessions_status ON sessions(status);
CREATE INDEX idx_sessions_created ON sessions(created_at);

-- Messages table
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    direction TEXT NOT NULL,                -- user_to_claude, claude_to_user
    message_type TEXT NOT NULL,             -- text, voice, command, response, error

    -- Content
    raw_content TEXT,                       -- Original input/output
    processed_content TEXT,                 -- Enhanced/reformatted

    -- Voice-specific
    voice_file_id TEXT,                     -- Telegram file_id
    voice_duration_sec INTEGER,
    transcription TEXT,

    -- Telegram reference
    telegram_message_id INTEGER,

    FOREIGN KEY (session_id) REFERENCES sessions(id)
);

CREATE INDEX idx_messages_session ON messages(session_id);
CREATE INDEX idx_messages_timestamp ON messages(timestamp);
CREATE INDEX idx_messages_direction ON messages(direction);

-- AI processing metrics
CREATE TABLE IF NOT EXISTS ai_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id INTEGER NOT NULL,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,

    process_type TEXT NOT NULL,             -- transcription, enhancement, reformatting
    provider TEXT,                          -- anthropic, openai, groq, local
    model TEXT,

    input_tokens INTEGER,
    output_tokens INTEGER,
    latency_ms INTEGER,
    cost_usd REAL,

    FOREIGN KEY (message_id) REFERENCES messages(id)
);

CREATE INDEX idx_metrics_message ON ai_metrics(message_id);
CREATE INDEX idx_metrics_type ON ai_metrics(process_type);

-- Conversation summaries (for context)
CREATE TABLE IF NOT EXISTS conversation_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    summary TEXT,
    message_range_start INTEGER,            -- First message id included
    message_range_end INTEGER,              -- Last message id included

    FOREIGN KEY (session_id) REFERENCES sessions(id)
);
```

#### Logging Functions

```bash
# File: src/db/log.sh

#!/bin/bash
# Log a message to the database

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/config.env"

DB_FILE="$SCRIPT_DIR/../../data/logs.db"

# Initialize DB if needed
if [[ ! -f "$DB_FILE" ]]; then
    sqlite3 "$DB_FILE" < "$SCRIPT_DIR/schema.sql"
fi

log_session_start() {
    local session_name="$1"
    local working_dir="$2"
    local initial_prompt="$3"

    sqlite3 "$DB_FILE" "
        INSERT INTO sessions (session_name, working_dir, initial_prompt)
        VALUES ('$session_name', '$working_dir', '$(echo "$initial_prompt" | sed "s/'/''/g")')
    "

    # Return the session_id
    sqlite3 "$DB_FILE" "SELECT id FROM sessions WHERE session_name='$session_name'"
}

log_session_end() {
    local session_name="$1"
    local status="${2:-stopped}"

    sqlite3 "$DB_FILE" "
        UPDATE sessions
        SET ended_at = CURRENT_TIMESTAMP, status = '$status'
        WHERE session_name = '$session_name' AND ended_at IS NULL
    "
}

log_message() {
    local session_name="$1"
    local direction="$2"
    local message_type="$3"
    local raw_content="$4"
    local processed_content="$5"
    local telegram_msg_id="${6:-}"

    # Get session_id
    local session_id=$(sqlite3 "$DB_FILE" "
        SELECT id FROM sessions WHERE session_name='$session_name' AND status='active'
    ")

    if [[ -z "$session_id" ]]; then
        echo "ERROR: No active session found for $session_name" >&2
        return 1
    fi

    # Escape single quotes for SQL
    raw_escaped=$(echo "$raw_content" | sed "s/'/''/g")
    processed_escaped=$(echo "$processed_content" | sed "s/'/''/g")

    sqlite3 "$DB_FILE" "
        INSERT INTO messages (session_id, direction, message_type, raw_content, processed_content, telegram_message_id)
        VALUES ($session_id, '$direction', '$message_type', '$raw_escaped', '$processed_escaped', ${telegram_msg_id:-NULL})
    "

    # Return the message_id
    sqlite3 "$DB_FILE" "SELECT last_insert_rowid()"
}

log_voice_message() {
    local session_name="$1"
    local file_id="$2"
    local duration="$3"
    local transcription="$4"
    local enhanced="$5"

    # Get session_id
    local session_id=$(sqlite3 "$DB_FILE" "
        SELECT id FROM sessions WHERE session_name='$session_name' AND status='active'
    ")

    transcription_escaped=$(echo "$transcription" | sed "s/'/''/g")
    enhanced_escaped=$(echo "$enhanced" | sed "s/'/''/g")

    sqlite3 "$DB_FILE" "
        INSERT INTO messages (session_id, direction, message_type, voice_file_id, voice_duration_sec, transcription, raw_content, processed_content)
        VALUES ($session_id, 'user_to_claude', 'voice', '$file_id', $duration, '$transcription_escaped', '$transcription_escaped', '$enhanced_escaped')
    "

    sqlite3 "$DB_FILE" "SELECT last_insert_rowid()"
}

log_ai_metrics() {
    local message_id="$1"
    local process_type="$2"
    local provider="$3"
    local model="$4"
    local latency_ms="$5"
    local input_tokens="${6:-0}"
    local output_tokens="${7:-0}"

    sqlite3 "$DB_FILE" "
        INSERT INTO ai_metrics (message_id, process_type, provider, model, input_tokens, output_tokens, latency_ms)
        VALUES ($message_id, '$process_type', '$provider', '$model', $input_tokens, $output_tokens, $latency_ms)
    "
}
```

#### Query Functions

```bash
# File: src/db/query.sh

#!/bin/bash
# Query the logs database

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_FILE="$SCRIPT_DIR/../../data/logs.db"

get_session_history() {
    local session_name="$1"
    local limit="${2:-50}"

    sqlite3 -header -column "$DB_FILE" "
        SELECT
            m.timestamp,
            m.direction,
            m.message_type,
            SUBSTR(m.raw_content, 1, 100) as content_preview
        FROM messages m
        JOIN sessions s ON m.session_id = s.id
        WHERE s.session_name = '$session_name'
        ORDER BY m.timestamp DESC
        LIMIT $limit
    "
}

get_context() {
    # Get recent exchanges for prompt enhancement context
    local session_name="$1"
    local exchanges="${2:-3}"

    sqlite3 "$DB_FILE" "
        SELECT
            CASE direction
                WHEN 'user_to_claude' THEN 'User: '
                ELSE 'Claude: '
            END || SUBSTR(COALESCE(processed_content, raw_content), 1, 200)
        FROM messages m
        JOIN sessions s ON m.session_id = s.id
        WHERE s.session_name = '$session_name'
        ORDER BY m.timestamp DESC
        LIMIT $((exchanges * 2))
    " | tac  # Reverse to chronological order
}

get_daily_stats() {
    local date="${1:-$(date +%Y-%m-%d)}"

    sqlite3 -header -column "$DB_FILE" "
        SELECT
            COUNT(DISTINCT s.id) as sessions,
            COUNT(m.id) as messages,
            SUM(CASE WHEN m.message_type = 'voice' THEN 1 ELSE 0 END) as voice_messages,
            ROUND(SUM(am.cost_usd), 4) as total_cost
        FROM sessions s
        LEFT JOIN messages m ON s.id = m.session_id
        LEFT JOIN ai_metrics am ON m.id = am.message_id
        WHERE DATE(s.created_at) = '$date'
    "
}

export_session() {
    # Export a session to JSON for backup/analysis
    local session_name="$1"
    local output_file="$2"

    sqlite3 "$DB_FILE" "
        SELECT json_object(
            'session', json_object(
                'name', s.session_name,
                'created_at', s.created_at,
                'ended_at', s.ended_at,
                'working_dir', s.working_dir,
                'status', s.status
            ),
            'messages', json_group_array(json_object(
                'timestamp', m.timestamp,
                'direction', m.direction,
                'type', m.message_type,
                'raw', m.raw_content,
                'processed', m.processed_content,
                'transcription', m.transcription
            ))
        )
        FROM sessions s
        LEFT JOIN messages m ON s.id = m.session_id
        WHERE s.session_name = '$session_name'
        GROUP BY s.id
    " > "$output_file"
}
```

---

### 5. Multi-Instance Handling

#### Session Identification Flow
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MULTI-INSTANCE ROUTING                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Incoming Message                                                            │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ CASE 1: Explicit session prefix                                     │    │
│  │                                                                      │    │
│  │ /1 fix the bug     →  Route to claude-1                             │    │
│  │ /2 check logs      →  Route to claude-2                             │    │
│  │ /3 3               →  Select option 3 in claude-3                   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ CASE 2: Reply to message                                            │    │
│  │                                                                      │    │
│  │ Original: "📝 [claude-1] What file should I edit?"                  │    │
│  │ Reply: "src/auth.ts"                                                 │    │
│  │                                                                      │    │
│  │ Extract [claude-1] from original → Route to claude-1                │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ CASE 3: No prefix, no reply                                         │    │
│  │                                                                      │    │
│  │ Find most recently active session                                   │    │
│  │ sessions/claude-* sorted by mtime → Route to most recent           │    │
│  │                                                                      │    │
│  │ If no active session → Error: "No active session. Use /new"        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ All outputs include session tag                                     │    │
│  │                                                                      │    │
│  │ notify.sh adds: "📝 [claude-1]" or "❓ [claude-2]"                  │    │
│  │                                                                      │    │
│  │ This enables reply-based routing for multi-turn conversations       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Session Status Dashboard

New command: `/dashboard`

```
📊 Claude Sessions Dashboard

🟢 claude-1 (active)
   Dir: ~/work/project-a
   Started: 2h ago
   Messages: 23 (5 voice)

🟢 claude-2 (active)
   Dir: ~/git/project-b
   Started: 45m ago
   Messages: 8

🔴 claude-3 (stopped)
   Dir: ~/work/sandbox
   Ended: 1h ago
   Messages: 15

━━━━━━━━━━━━━━━━━
Today: 46 messages | 5 voice | $0.02 AI cost
```

---

## Directory Structure (Final)

```
~/git/gergokiss-work/claude-telegram-orchestrator/
├── README.md                        # Quick start guide
├── ARCHITECTURE.md                  # Detailed architecture
├── PLAN-V2-ENHANCED.md             # This document
├── LICENSE                          # MIT
├── .gitignore
├── .env.example                     # Template for secrets
│
├── config/
│   ├── config.env                   # Main config (gitignored)
│   ├── config.env.example           # Template
│   └── models.yaml                  # AI model configurations
│
├── src/
│   ├── orchestrator.sh              # Main daemon
│   ├── session-monitor.sh           # Monitor Claude sessions
│   ├── start-claude.sh              # Create new sessions
│   ├── notify.sh                    # Send Telegram notifications
│   │
│   ├── voice/
│   │   ├── process.sh               # Full voice pipeline
│   │   ├── download.sh              # Download from Telegram
│   │   ├── convert.sh               # OGA → WAV
│   │   └── transcribe.sh            # Whisper API
│   │
│   ├── ai/
│   │   ├── enhance.sh               # Prompt enhancement
│   │   ├── reformat.sh              # Output reformatting
│   │   └── summarize.sh             # Long output summarization
│   │
│   ├── db/
│   │   ├── schema.sql               # Database schema
│   │   ├── init.sh                  # Initialize database
│   │   ├── log.sh                   # Logging functions
│   │   └── query.sh                 # Query functions
│   │
│   └── utils/
│       ├── telegram-api.sh          # Telegram API helpers
│       └── cleanup.sh               # Cleanup temp files
│
├── hooks/                           # Claude Code hooks
│   ├── post-tool.sh
│   └── notification.sh
│
├── scripts/
│   ├── install.sh                   # Full installation
│   ├── upgrade.sh                   # Upgrade from v1
│   ├── uninstall.sh                 # Clean removal
│   └── test-all.sh                  # Run all tests
│
├── launchd/
│   └── com.claude.telegram-orchestrator.plist
│
├── data/                            # Runtime data (gitignored)
│   ├── logs.db                      # SQLite database
│   ├── sessions/                    # Active session tracking
│   └── temp/                        # Temporary files
│
├── logs/                            # Log files (gitignored)
│   ├── orchestrator.log
│   └── monitor-*.log
│
└── tests/
    ├── test-voice.sh                # Voice pipeline tests
    ├── test-enhance.sh              # Enhancement tests
    ├── test-reformat.sh             # Reformatting tests
    └── test-db.sh                   # Database tests
```

---

## Configuration Template

```bash
# File: config/config.env.example

# ═══════════════════════════════════════════════════════════════════
# TELEGRAM CONFIGURATION
# ═══════════════════════════════════════════════════════════════════
TELEGRAM_BOT_TOKEN=""                    # From @BotFather
TELEGRAM_CHAT_ID=""                      # Auto-detected on first message

# ═══════════════════════════════════════════════════════════════════
# AI API KEYS
# ═══════════════════════════════════════════════════════════════════
ANTHROPIC_API_KEY=""                     # For Claude Haiku
OPENAI_API_KEY=""                        # For Whisper / GPT
GROQ_API_KEY=""                          # For fast inference

# ═══════════════════════════════════════════════════════════════════
# VOICE TRANSCRIPTION (Whisper)
# ═══════════════════════════════════════════════════════════════════
WHISPER_ENABLED=true
WHISPER_PROVIDER="groq"                  # groq, openai, local
WHISPER_MODEL="whisper-large-v3"         # For groq
WHISPER_LANGUAGE=""                      # Empty = auto-detect, or "en", "hu"

# ═══════════════════════════════════════════════════════════════════
# PROMPT ENHANCEMENT
# ═══════════════════════════════════════════════════════════════════
ENHANCE_ENABLED=true
ENHANCE_PROVIDER="anthropic"             # anthropic, openai, groq
ENHANCE_MODEL="claude-3-haiku-20240307"
ENHANCE_MIN_LENGTH=5                     # Don't enhance very short inputs
ENHANCE_MAX_LENGTH=100                   # Don't enhance already detailed prompts

# ═══════════════════════════════════════════════════════════════════
# OUTPUT REFORMATTING
# ═══════════════════════════════════════════════════════════════════
REFORMAT_ENABLED=true
REFORMAT_PROVIDER="anthropic"
REFORMAT_MODEL="claude-3-haiku-20240307"
REFORMAT_THRESHOLD=2000                  # Chars before summarizing

# ═══════════════════════════════════════════════════════════════════
# ORCHESTRATOR SETTINGS
# ═══════════════════════════════════════════════════════════════════
POLL_INTERVAL=5                          # Seconds between Telegram polls
MAX_SESSIONS=5                           # Maximum concurrent Claude sessions
SESSION_IDLE_TIMEOUT=300                 # Seconds before idle notification

# ═══════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════
LOG_LEVEL="info"                         # debug, info, warn, error
LOG_RETENTION_DAYS=30                    # Days to keep logs
EXPORT_ON_SESSION_END=true               # Auto-export session to JSON

# ═══════════════════════════════════════════════════════════════════
# OPTIONAL: TTS READ-ALOUD
# ═══════════════════════════════════════════════════════════════════
TTS_ENABLED=false
TTS_VOICE="Daniel"                       # macOS voice
```

---

## Implementation Phases

### Phase 1: Repository Restructure (1-2 hours)
- [ ] Create new directory structure in existing repo
- [ ] Move and refactor existing scripts into `src/`
- [ ] Create config templates
- [ ] Update install.sh for new structure
- [ ] Create .gitignore for data/logs
- [ ] Symlink from ~/.claude/telegram-orchestrator for LaunchAgent compatibility

### Phase 2: Database & Logging (2-3 hours)
- [ ] Create SQLite schema
- [ ] Implement log.sh functions
- [ ] Implement query.sh functions
- [ ] Add logging calls to orchestrator.sh
- [ ] Add logging calls to session-monitor.sh
- [ ] Test multi-session logging

### Phase 3: Voice Pipeline (2-3 hours)
- [ ] Implement voice detection in orchestrator.sh
- [ ] Create download.sh (Telegram file API)
- [ ] Create convert.sh (ffmpeg OGA→WAV)
- [ ] Create transcribe.sh (Whisper API)
- [ ] Create process.sh (full pipeline)
- [ ] Integrate into message flow
- [ ] Test with real voice messages

### Phase 4: Prompt Enhancement (2 hours)
- [ ] Create enhance.sh with Haiku integration
- [ ] Add context loading from database
- [ ] Add bypass rules (commands, long inputs)
- [ ] Integrate into orchestrator.sh
- [ ] Log original vs enhanced prompts
- [ ] Test with various input types

### Phase 5: Output Reformatting (2 hours)
- [ ] Improve ANSI stripping
- [ ] Improve noise filtering regex
- [ ] Create reformat.sh with summarization
- [ ] Integrate into session-monitor.sh
- [ ] Log raw vs formatted outputs
- [ ] Test with various output types

### Phase 6: Polish & Documentation (1-2 hours)
- [ ] Update README.md with new features
- [ ] Update ARCHITECTURE.md
- [ ] Create upgrade.sh from v1
- [ ] Add error handling throughout
- [ ] Create test scripts
- [ ] Performance optimization

---

## Cost Estimates

### Per Voice Message
| Component | Provider | Cost |
|-----------|----------|------|
| Whisper transcription | Groq | ~$0.0001 (10s audio) |
| Prompt enhancement | Haiku | ~$0.0003 (500 tokens) |
| **Total per voice** | | **~$0.0004** |

### Per Long Response
| Component | Provider | Cost |
|-----------|----------|------|
| Output reformatting | Haiku | ~$0.0005 (1000 tokens) |
| **Total per long output** | | **~$0.0005** |

### Daily Estimate (50 messages, 10 voice, 5 long outputs)
- Voice: 10 × $0.0004 = $0.004
- Long outputs: 5 × $0.0005 = $0.0025
- **Daily total: ~$0.007** (less than 1 cent)

---

## Next Steps

1. **Review this plan** - Confirm architecture decisions
2. **Set up API keys** - Groq (free tier), verify Anthropic key
3. **Begin Phase 1** - Repository restructure
4. **Iterate** - Each phase should be testable independently

---

*Document created: January 9, 2026*
*Author: Claude (claude-1 session)*
