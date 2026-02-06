# Telegram Orchestrator: Comprehensive Audit & Improvement Plan

**Date:** 2026-02-05
**Author:** claude-0 (coordinator)
**Scope:** Full system audit, Opus 4.6 compatibility, improvement roadmap

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current Architecture Overview](#2-current-architecture-overview)
3. [Codebase Audit Findings](#3-codebase-audit-findings)
4. [Opus 4.6 Gap Analysis](#4-opus-46-gap-analysis)
5. [Auto-Respawn & Teammate Problem](#5-auto-respawn--teammate-problem)
6. [Dual-Account Management & Rotation](#6-dual-account-management--rotation)
7. [Agent Naming Convention](#7-agent-naming-convention)
8. [Enhanced Handoff Protocol](#8-enhanced-handoff-protocol)
9. [TTS Service Improvements](#9-tts-service-improvements)
10. [Telegram Reporting & Replies](#10-telegram-reporting--replies)
11. [Statusline Enhancements](#11-statusline-enhancements)
12. [Security Issues](#12-security-issues)
13. [Future Vision](#13-future-vision)
14. [Implementation Roadmap](#14-implementation-roadmap)

---

## 1. Executive Summary

The telegram-orchestrator is a ~4,500-line bash-based system managing multi-agent Claude Code sessions. It provides Telegram-based remote control, auto-respawn at context thresholds, circuit breaker protection, TTS summaries, and RALPH autonomous task execution.

**What works well:**
- Auto-respawn system is production-proven (2,139+ log entries over 15 days)
- Modular architecture (separate concerns: watching, injecting, analyzing)
- Circuit breaker prevents runaway loops
- Dual-gate RALPH verification (EXIT_SIGNAL + status match)

**What needs improvement:**
- Auto-respawn kills sessions that have spawned Agent Teams teammates (Opus 4.6 critical issue)
- No intelligent rotation between two Max subscription accounts
- Agent naming creates confusion across accounts in Telegram
- Handoff files lack service/parameter/database tracking
- TTS has no queueing or bulk reporting
- No subscription usage tracking or display
- Security: credentials in plaintext config.env

---

## 2. Current Architecture Overview

### 2.1 File Map (~4,500 lines total)

```
~/.claude/telegram-orchestrator/
├── orchestrator.sh          (1,227 lines) - Main Telegram polling daemon
├── watchdog.sh              (939 lines)   - Session monitoring & circuit breaker
├── ralph-task.sh            (~350 lines)  - Task file management
├── ralph-worker.sh          (~150 lines)  - Autonomous loop runner
├── ralph-status.sh          (191 lines)   - Worker status display
├── start-claude.sh          (204 lines)   - Session spawning
├── start-lobby.sh           (37 lines)    - Clawdbot monitoring
├── find-session.sh          (185 lines)   - Semantic session search
├── inject-prompt.sh         (147 lines)   - Reliable prompt injection
├── send-summary.sh          (81 lines)    - Telegram message formatting
├── notify.sh                (46 lines)    - Notification system
├── lib/
│   ├── circuit_breaker.sh   (346 lines)   - 3-state circuit breaker
│   ├── rate_limiter.sh      (218 lines)   - Hourly rate limiting
│   ├── exit_detector.sh     (288 lines)   - Multi-condition exit detection
│   └── response_analyzer.sh (272 lines)   - Claude output parsing
├── config.env               - Configuration (HAS CREDENTIALS!)
├── .env.local               - Secrets (gitignored)
├── sessions/                - Session metadata (JSON)
├── logs/                    - Log files
├── watchdog-state/          - Circuit breaker state files
└── worker-state/            - RALPH worker state
```

### 2.2 Supporting System (~1,500 lines)

```
~/.claude/scripts/
├── auto-respawn.sh          (271 lines) - Full handoff→kill→respawn→inject
├── auto-respawn-toggle.sh   (56 lines)  - Enable/disable/exclude sessions
├── trigger-handoff.sh       - Orchestrates handoff decision
├── check-context.sh         (45 lines)  - Context % query
├── statusline.sh            (61 lines)  - Real-time context display + trigger
├── tts-write.sh             - Queue TTS summary
├── tts-reader.sh            - Sequential TTS reader
├── tts-toggle.sh            - TTS daemon control
├── hub-session-start.sh     (83 lines)  - Agent Hub session_start
├── hub-session-stop.sh      (45 lines)  - Agent Hub task_complete
├── handoff-log.sh           (30 lines)  - Append to handoff file
├── get-timestamp.sh         (46 lines)  - Timestamp formatting
└── context-collector.sh     (187 lines) - System info gathering
```

### 2.3 Data Flow

```
Claude Instance (tmux)
    │
    ├─→ statusline.sh (every message turn)
    │       │
    │       ├─ Calculate: (INPUT + OUTPUT + CACHE_CREATE + CACHE_READ) / 200K
    │       │
    │       └─ IF >= 60%: trigger-handoff.sh → auto-respawn.sh
    │               │
    │               ├─ Inject "finalize handoff" message
    │               ├─ Wait up to 300s for handoff file
    │               ├─ Extract continuation prompt
    │               ├─ Kill old session
    │               ├─ Start fresh session
    │               ├─ Inject continuation prompt
    │               └─ Notify orchestrator + Telegram
    │
    ├─→ Telegram (bidirectional via orchestrator.sh)
    │       ├─ User sends command → routed to session
    │       └─ Agent calls send-summary.sh → formatted message to user
    │
    └─→ Agent Hub (MCP server)
            ├─ Session start: post + fetch briefing
            └─ Session stop: post completion summary
```

---

## 3. Codebase Audit Findings

### 3.1 Strengths

| Area | Assessment |
|------|-----------|
| Modular design | Separate concerns (watching, injecting, analyzing) |
| Library architecture | Reusable circuit breaker, rate limiter |
| Dual-gate verification | EXIT_SIGNAL + status matching prevents false exits |
| Account separation | Handles `-acc2` suffix for secondary account |
| Graceful degradation | Fallback from API to keyword search (find-session.sh) |
| Inject reliability | tmux buffer loading + adaptive delays + retry (5x) |

### 3.2 Weaknesses

| Area | Issue | Severity |
|------|-------|----------|
| Input validation | User input from Telegram passed to tmux unsanitized | HIGH |
| Race conditions | Multiple processes modify session/state files simultaneously | MEDIUM |
| Error handling | jq failures silently default to empty values | MEDIUM |
| Polling architecture | 5-second latency minimum, not event-driven | LOW |
| State explosion | Too many state files (circuit, rate limit, exit signals, response) | LOW |
| No tests | Zero test files found | MEDIUM |
| Tight coupling | orchestrator.sh knows about all command types | LOW |

### 3.3 Technical Debt

- No atomic state updates or file locking
- Heavy use of grep/sed instead of structured JSON parsing
- Inconsistent error recovery patterns
- Ad-hoc message routing
- Manual retry logic duplicated across files
- `find-session.sh` still uses claude-3-5-haiku (outdated model reference)

---

## 4. Opus 4.6 Gap Analysis

### 4.1 What Opus 4.6 Brings

| Feature | Current System Impact |
|---------|----------------------|
| **1M token context window** | Context math assumes 200K. Threshold at 60% = 120K tokens. With 1M window, 60% = 600K tokens -- sessions could run MUCH longer before needing respawn |
| **Agent Teams** | Native multi-agent coordination. Sessions can spawn teammates that work in parallel. Auto-respawn kills the parent session, destroying ALL teammates |
| **Context Compaction** | Built-in summarization replaces old context. May reduce need for aggressive respawn |
| **Adaptive Thinking** | Model decides when to think deeper. No changes needed but good to document |
| **Effort Controls** | Could be used to optimize token usage per task type |

### 4.2 Critical: Context Window Size Detection

**Problem:** `statusline.sh` line 8 reads context_window_size from Claude's JSON, but the percentage calculation may not account for the 1M beta window correctly. If Claude reports 1M as context size, the 60% threshold moves to 600K tokens -- which means sessions will run 5x longer before respawning.

**Recommendation:**
```bash
# In statusline.sh, add dynamic threshold adjustment:
if [ "$CONTEXT_SIZE" -gt 500000 ]; then
    # With 1M window, use absolute token threshold instead of percentage
    # e.g., respawn at 150K tokens regardless of window size
    ABSOLUTE_THRESHOLD=150000
    if [ "$TOTAL_TOKENS" -ge "$ABSOLUTE_THRESHOLD" ]; then
        # trigger respawn
    fi
fi
```

### 4.3 Critical: Agent Teams Compatibility

**Problem:** When Opus 4.6 spawns Agent Teams (via the `spawnTeam` / `TeammateTool` mechanism), the parent session coordinates teammates. If auto-respawn kills the parent session, ALL teammates are destroyed with no warning.

**Current behavior:**
1. Agent at 60% context spawns 3 teammates
2. Statusline triggers auto-respawn
3. auto-respawn.sh kills the parent tmux session
4. All 3 teammates are orphaned/killed
5. Work is lost

**Proposed solution -- see Section 5.**

### 4.4 Outdated Model References

- `find-session.sh` line 56: Uses `claude-3-5-haiku-20241022` -- should use `claude-haiku-4-5-20251001`
- Any hardcoded model references should be configurable

---

## 5. Auto-Respawn & Teammate Problem

### 5.1 The Problem

Opus 4.6's Agent Teams feature creates in-process subagents (teammates). These are NOT tmux sessions -- they're internal Claude Code processes. When auto-respawn kills the tmux session, it kills the Claude Code process and all its internal teammates.

### 5.2 Detection Strategy

Before killing a session, auto-respawn should detect if teammates are active:

```bash
# Option A: Check Claude Code's task list output
# Capture pane and look for active task indicators
OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
if echo "$OUTPUT" | grep -qE "teammates|team lead|peer message"; then
    log "[$SESSION] Agent Teams detected - delaying respawn"
    # Wait for team completion or force handoff
fi

# Option B: Check for subprocesses
CLAUDE_PID=$(tmux list-panes -t "$SESSION" -F '#{pane_pid}')
CHILD_COUNT=$(pgrep -P "$CLAUDE_PID" | wc -l)
if [ "$CHILD_COUNT" -gt 2 ]; then
    log "[$SESSION] Multiple child processes ($CHILD_COUNT) - likely teammates"
fi
```

### 5.3 Proposed Solutions

**Solution 1: Teammate-Aware Respawn (Recommended)**
- Before respawn, inject: "You have active teammates. Please wait for them to complete, then create your handoff."
- Increase timeout to 600s when teammates detected
- Only kill when no child processes remain

**Solution 2: Session Exclusion During Team Work**
- When an agent spawns teammates, it writes a lock file: `~/.claude/handoffs/.team-active-$SESSION`
- Auto-respawn checks for this file and skips the session
- Agent removes the lock when team work completes

**Solution 3: Handoff Includes Teammate State**
- Enhanced handoff template includes a "Active Teammates" section
- Lists each teammate's task and progress
- New session can re-spawn teammates with remaining tasks

### 5.4 Handoff Enhancement for Teams

Add to HANDOFF_V2.md template:

```markdown
## 🤝 Agent Teams State (if applicable)

**Team Active:** Yes/No
**Team Lead:** This agent / Another agent
**Teammates:**

| Teammate | Task | Status | Progress |
|----------|------|--------|----------|
| teammate-1 | API endpoint tests | IN_PROGRESS | 60% |
| teammate-2 | Database migration | COMPLETE | 100% |
| teammate-3 | Frontend components | BLOCKED | 30% |

**Unfinished Team Work:**
- teammate-1 needs to complete: test cases for auth endpoints
- teammate-3 blocked on: design tokens not yet defined
```

---

## 6. Dual-Account Management & Rotation

### 6.1 Current State

Two Max subscriptions:
- **Account 1:** `gergo.kiss@netlocksolutions.com` → `~/.claude/` config
- **Account 2:** `kiss.gergo@netlock.hu` → `~/.claude-account2/` config

Current rotation: Manual via `account-manager/rotate.sh` or watchdog rate-limit detection triggers auto-migration to Account 2.

### 6.2 Problems

1. **No usage tracking** -- can't see how close each account is to weekly limit
2. **No intelligent rotation** -- rotation only happens AFTER hitting a rate limit (reactive, not proactive)
3. **No load balancing** -- all agents default to Account 1
4. **Rate limit detection is pattern-based** -- looks for "You've hit your limit" in output
5. **No weekly limit awareness** -- both accounts have rolling 7-day windows

### 6.3 Proposed: Usage Tracking System

```bash
# New file: ~/.claude/account-manager/usage-tracker.sh

# Track token usage per account per day
USAGE_DIR="$HOME/.claude/account-manager/usage"
mkdir -p "$USAGE_DIR"

# Log format: ~/.claude/account-manager/usage/YYYY-MM-DD-acc1.json
# {
#   "account": "gergo.kiss@netlocksolutions.com",
#   "date": "2026-02-05",
#   "input_tokens": 1500000,
#   "output_tokens": 450000,
#   "sessions_used": 8,
#   "rate_limit_hits": 0,
#   "estimated_weekly_percent": 35
# }

# Statusline could show: [Opus 4.6] 🟢 17% | ACC1: 35% weekly | ACC2: 12% weekly
```

### 6.4 Proposed: Intelligent Rotation Strategy

```
Account Selection Logic:
1. Check both accounts' estimated weekly usage
2. Select account with LOWER usage percentage
3. If both above 80%: WARN user via Telegram
4. If one above 90%: Force all new sessions to other account
5. If both above 90%: Reduce session count, warn user

Session Assignment:
- claude-0 through claude-3: Account 1 (primary)
- claude-4 through claude-7: Account 2 (secondary)
- Rotate when one account hits 70% weekly
- Emergency: migrate all to healthier account at 90%
```

### 6.5 Implementation: Account Rotation Service

New script: `~/.claude/account-manager/smart-rotate.sh`

```bash
#!/bin/bash
# Smart account rotation based on usage

ACC1_USAGE=$(get_weekly_usage "acc1")  # Returns 0-100%
ACC2_USAGE=$(get_weekly_usage "acc2")  # Returns 0-100%

# Decision matrix
if [ "$ACC1_USAGE" -lt 70 ] && [ "$ACC2_USAGE" -lt 70 ]; then
    # Both healthy: alternate by session number
    if [ $((SESSION_NUM % 2)) -eq 0 ]; then
        echo "acc1"
    else
        echo "acc2"
    fi
elif [ "$ACC1_USAGE" -ge 70 ] && [ "$ACC2_USAGE" -lt 70 ]; then
    echo "acc2"
elif [ "$ACC2_USAGE" -ge 70 ] && [ "$ACC1_USAGE" -lt 70 ]; then
    echo "acc1"
else
    # Both stressed: use less-used account, reduce sessions
    if [ "$ACC1_USAGE" -lt "$ACC2_USAGE" ]; then
        echo "acc1"
    else
        echo "acc2"
    fi
fi
```

### 6.6 Usage Estimation Method

Since there's no direct API to query Max subscription usage percentage, we can estimate:

```bash
# Method 1: Track from statusline data
# Each message turn reports token counts in statusline input JSON
# Accumulate daily: input_tokens + output_tokens + cache_creation

# Method 2: Detect usage warnings
# Claude shows warnings like "You've used 80% of your weekly usage"
# Pattern match in watchdog.sh output scanning

# Method 3: Rate limit timing
# When rate limited, note the timestamp
# "Your limit resets in X hours" → calculate weekly position

# Best: Combine all three for most accurate picture
```

---

## 7. Agent Naming Convention

### 7.1 Current Problem

With two accounts, both can have a `claude-1` session. In tmux, these are distinguished by `-acc2` suffix. But in Telegram messages, both show as `[claude-1]` or `[claude-1-acc2]`, creating confusion.

### 7.2 Proposed: Account-Prefixed Naming

```
Account 1 (gergo.kiss@netlocksolutions.com):
  Sessions: ns-0, ns-1, ns-2, ns-3  (ns = NetlockSolutions)
  Telegram: [ns-0] [ns-1] ...

Account 2 (kiss.gergo@netlock.hu):
  Sessions: nl-0, nl-4, nl-5, nl-6  (nl = Netlock.hu)
  Telegram: [nl-4] [nl-5] ...
```

Or simpler:
```
Account 1: a1-0, a1-1, a1-2, a1-3
Account 2: a2-4, a2-5, a2-6, a2-7
```

### 7.3 Telegram Message Enhancement

Current format:
```
📝 [claude-3]
✅ <b>Task Complete</b>
...
```

Proposed format:
```
📝 [ns-3 | ACC1 42%]
✅ <b>Task Complete</b>
🎯 <b>Request:</b> ...
📋 <b>Result:</b> ...
📊 ACC1: 42% weekly | ACC2: 18% weekly
```

### 7.4 Telegram Reply Routing

Currently: Replies to messages route back to the session that sent them (via `[session-name]` tag detection).

Enhancement: Also support cross-session replies:
```
User replies to [ns-3] message: "also tell ns-5 to check the database"
→ orchestrator.sh detects cross-session reference
→ injects message to ns-5 as well
```

---

## 8. Enhanced Handoff Protocol

### 8.1 Current Gaps

The HANDOFF_V2.md template is good but missing:
1. **Services used** -- which MCP servers, APIs, databases were touched
2. **Parameters/variables changed** -- env vars, configs modified
3. **Active subprocesses** -- teammates, background tasks
4. **Significance classification** -- not all actions are equally important

### 8.2 Proposed: HANDOFF_V3.md Additions

```markdown
## 🔌 Services & Integrations Used

| Service | Type | Details |
|---------|------|---------|
| Agent Hub MCP | MCP Server | Posted 3 updates, read 2 briefings |
| GitHub API | CLI (gh) | Checked PR #106, reviewed checks |
| Keycloak | REST API | https://auth.aws.netlock.cloud - queried users |
| MariaDB | Database | on-prem, SAM database - deleted 7 records |
| n8n | Webhook | https://n8n.dev.netlock.cloud - sent Teams message |

## ⚙️ Parameters & Variables Modified

| Item | Type | Before | After | File/Location |
|------|------|--------|-------|---------------|
| REDIS_URL | env var | (empty) | redis://... | deployment.yaml |
| threshold_percent | config | 50 | 60 | handoff-config.json |
| auth_timeout | code | 3600 | 7200 | src/auth/config.ts:45 |

## 🔧 Functions Modified

| Function | File:Line | Change | Why |
|----------|-----------|--------|-----|
| validateToken() | src/auth.ts:89 | Added refresh logic | Token was expiring mid-session |
| getUsers() | src/api/users.ts:34 | Added pagination | Was returning 10k records |

## 🤝 Agent Teams State

**Team Active:** No
**Teammates Spawned This Session:** 2
**All Completed:** Yes

## 📊 Significance Levels

Each action in the Action Log gets a significance marker:

- 🔴 CRITICAL: Data modification, config change, deployment
- 🟡 IMPORTANT: File edit, API call, test result
- 🟢 ROUTINE: File read, status check, exploration
```

### 8.3 Implementation: Auto-Logging Hook

Agents should log automatically. Enhance `handoff-log.sh`:

```bash
#!/bin/bash
# Enhanced handoff-log.sh with significance detection

ACTION="$1"
RESULT="$2"
SIGNIFICANCE="🟢"  # default: ROUTINE

# Auto-detect significance
if echo "$ACTION" | grep -qiE "edit|modify|delete|create|deploy|push"; then
    SIGNIFICANCE="🔴"
elif echo "$ACTION" | grep -qiE "test|build|api|install|migrate"; then
    SIGNIFICANCE="🟡"
fi

TIMESTAMP=$(~/.claude/scripts/get-timestamp.sh time)
SESSION=$(tmux display-message -p '#S')
HANDOFF=$(ls -t ~/.claude/handoffs/${SESSION}-*.md 2>/dev/null | head -1)

if [ -n "$HANDOFF" ]; then
    echo "| $TIMESTAMP | $SIGNIFICANCE $ACTION | $RESULT |" >> "$HANDOFF"
fi
```

### 8.4 Consistency Enforcement

Add a PostToolUse hook that auto-appends to handoff when significant tools are used:

```json
{
  "hooks": {
    "PostToolUse:Bash": [{
      "type": "command",
      "command": "~/.claude/scripts/handoff-log-hook.sh",
      "async": true
    }],
    "PostToolUse:Edit": [{
      "type": "command",
      "command": "~/.claude/scripts/handoff-log-hook.sh",
      "async": true
    }]
  }
}
```

---

## 9. TTS Service Improvements

### 9.1 Current State

- `tts-write.sh`: Queues 1-2 sentence summaries as text files
- `tts-reader.sh`: Sequential reader with locking, polls every 2s
- Voice: Daniel, Rate: 200 WPM
- Triggered at session stop (settings.json hook)

### 9.2 Problems

1. **No queue management** -- if multiple agents finish simultaneously, TTS reads overlap or one blocks others
2. **No priority system** -- urgent errors read in same order as routine completions
3. **No bulk mode** -- can't batch multiple agent reports into one coherent readout
4. **macOS `say` only** -- no cross-platform support

### 9.3 Proposed: TTS Queue Manager

```bash
# Enhanced queue with priority and batching

QUEUE_DIR="$HOME/.claude/tts/queue"
# File naming: PRIORITY-TIMESTAMP-SESSION-PID.txt
# Priority: 1=URGENT, 2=IMPORTANT, 3=ROUTINE

# Example queue:
# 1-1738780800-claude-3-error.txt     ← Read first (error)
# 2-1738780801-claude-1-complete.txt  ← Read second
# 3-1738780802-claude-5-status.txt    ← Read last

# Batch mode (called by claude-0):
tts-batch.sh  # Reads all pending, grouped by priority
# Output: "Three agent updates. First, urgent: claude-3 encountered an error...
#          Next, claude-1 completed the frontend task...
#          Finally, claude-5 reports CI review at 60% progress."
```

### 9.4 Proposed: Coordinator Digest Mode

When TTS is enabled and claude-0 (coordinator) collects multiple summaries:

```bash
# claude-0 calls:
tts-digest.sh

# Behavior:
# 1. Collect all pending TTS messages (wait 10s for stragglers)
# 2. Group by priority (errors first, completions, then status)
# 3. Synthesize into natural speech:
#    "You have 4 agent updates.
#     claude-3 hit an error on PR 106 - needs your review approval.
#     claude-1 finished the frontend status check - app is building correctly.
#     claude-5 completed CI dead code review - ready for your push approval.
#     claude-7 is at 54% context working on Agent Hub frontend."
# 4. Read as single coherent block
```

### 9.5 Future: Voice Call Integration

**Phase 1 (Current):** TTS via macOS `say` command (local speaker)
**Phase 2 (Near-term):** Telegram voice message via Bot API
**Phase 3 (Future):** Real-time voice call where claude-0 reports and user can respond

Phase 2 implementation sketch:
```bash
# Generate audio file from summary
say -o /tmp/agent-report.aiff "$SUMMARY_TEXT"
# Convert to OGG (Telegram voice format)
ffmpeg -i /tmp/agent-report.aiff -c:a libopus /tmp/agent-report.ogg
# Send as voice message
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendVoice" \
    -F "chat_id=${CHAT_ID}" \
    -F "voice=@/tmp/agent-report.ogg" \
    -F "caption=Agent Digest Report"
```

---

## 10. Telegram Reporting & Replies

### 10.1 Current Limitations

- User can only reply to the specific session that sent a message
- No way to send a command to a specific agent from a reply
- No cross-agent messaging (e.g., "tell claude-5 to also check X")
- No inline keyboard buttons for quick actions (approve, reject, retry)

### 10.2 Proposed: Enhanced Reply Parsing

```bash
# In orchestrator.sh process_message():

# Detect cross-session references
if echo "$TEXT" | grep -qE '@(claude|ns|nl|a[12])-[0-9]+'; then
    TARGET=$(echo "$TEXT" | grep -oE '(claude|ns|nl|a[12])-[0-9]+' | head -1)
    # Route message to both reply session AND mentioned session
fi

# Detect action commands in replies
if echo "$TEXT" | grep -qiE '^(approve|reject|retry|skip|merge|push)'; then
    ACTION=$(echo "$TEXT" | awk '{print tolower($1)}')
    # Convert to appropriate injection
    case "$ACTION" in
        approve) inject_input "$SESSION" "Yes, approved. Proceed." ;;
        reject)  inject_input "$SESSION" "No, do not proceed. Reason: ${TEXT#* }" ;;
        retry)   inject_input "$SESSION" "Please retry the last action." ;;
        merge)   inject_input "$SESSION" "Merge the PR now." ;;
    esac
fi
```

### 10.3 Proposed: Status Dashboard Message

Periodic (every 30 min) or on-demand dashboard:

```
📊 <b>Agent Dashboard</b> (20:15)

<b>Account Usage:</b>
ACC1 (netlocksolutions): ████████░░ 78% weekly
ACC2 (netlock.hu):       ███░░░░░░░ 28% weekly

<b>Active Agents:</b>
🟢 ns-0  │ 17% │ Coordinator (idle)
🟢 ns-1  │ 35% │ Frontend status check
🟢 ns-2  │ 42% │ Issue #73
🟡 ns-3  │ 55% │ PR #106 ⚠️ approaching threshold
⏸️ nl-4  │ 16% │ Idle
🟢 nl-5  │ 28% │ CI dead code review
🟢 nl-6  │ 19% │ Agent Hub tasks
🟡 nl-7  │ 51% │ Agent Hub frontend ⚠️

<b>Recent Completions:</b>
✅ ns-2: Keycloak cleanup (7 records deleted)
✅ nl-4: Teams message sent to Dávid

<b>Alerts:</b>
⚠️ ns-3 at 55% - will respawn in ~10 min
⚠️ nl-7 at 51% - will respawn in ~15 min
```

---

## 11. Statusline Enhancements

### 11.1 Current Display

```
[Opus 4.6] 🟢 17% (35k) | 83% left
```

### 11.2 Proposed Display

```
[Opus 4.6] 🟢 17% (35k) | 83% left | ns-1@ACC1 42%wk
```

Components:
- Model name and version
- Context usage (% and tokens)
- Remaining capacity
- **NEW:** Session name with account prefix
- **NEW:** Account weekly usage percentage

### 11.3 Implementation

Modify `statusline.sh` to read account info:

```bash
# Detect which account this session uses
if [ -n "$CLAUDE_CONFIG_DIR" ] && [[ "$CLAUDE_CONFIG_DIR" == *account2* ]]; then
    ACCOUNT="ACC2"
    ACCOUNT_EMAIL="kiss.gergo@netlock.hu"
else
    ACCOUNT="ACC1"
    ACCOUNT_EMAIL="gergo.kiss@netlocksolutions.com"
fi

# Read weekly usage estimate
WEEKLY_PCT=$(cat "$HOME/.claude/account-manager/usage/weekly-$ACCOUNT.txt" 2>/dev/null || echo "?")

# Enhanced output
echo "[$MODEL] $COLOR ${PERCENT}% (${TOKENS_DISPLAY}) | ${REMAIN}% left | $SESSION@$ACCOUNT ${WEEKLY_PCT}%wk"
```

---

## 12. Security Issues

### 12.1 Critical: Credentials in config.env

**File:** `config.env` contains plaintext:
- Telegram Bot Token
- Telegram Chat ID
- N8N Base URL
- N8N API Key (JWT)

**Recommendation:** Move ALL credentials to `.env.local` (gitignored) or use macOS Keychain:

```bash
# Option A: .env.local only (simplest)
# Move all secrets from config.env to .env.local
# config.env should only contain non-secret configuration

# Option B: macOS Keychain
security add-generic-password -a "telegram-orchestrator" -s "bot-token" -w "$TOKEN"
TOKEN=$(security find-generic-password -a "telegram-orchestrator" -s "bot-token" -w)
```

### 12.2 Input Validation

All Telegram inputs should be sanitized before tmux injection:

```bash
sanitize_input() {
    local input="$1"
    # Remove shell metacharacters
    input=$(echo "$input" | sed 's/[;&|`$(){}]//g')
    # Limit length
    input="${input:0:2000}"
    echo "$input"
}
```

### 12.3 File Locking

State files modified by multiple processes need locking:

```bash
# Use flock for atomic updates
(
    flock -x 200
    jq ".field = \"$value\"" "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
) 200>"$STATE_FILE.lock"
```

---

## 13. Future Vision

### 13.1 Voice Call Briefings (Phase 3)

claude-0 collects all agent reports and calls the user via Telegram voice call:

```
"Good evening Gergo. Here's your agent briefing for the last hour.

Five agents reported in. claude-3 completed the PR 106 review - all CI checks
pass and it's ready for your merge approval. claude-1 analyzed the frontend
project - the build is healthy, 4 issues found in the backlog.

Two items need your attention:
First, claude-2 is blocked on Issue 73 - the back-side detection test needs
a sample image you haven't provided yet.
Second, Account 1 is at 78% weekly usage. I recommend shifting new tasks
to Account 2 which is at 28%.

You can reply now with approvals or I'll wait for your Telegram messages."
```

### 13.2 Intelligent Task Assignment

claude-0 becomes a true project manager:

```
Assignment Logic:
1. Read incoming task request
2. Evaluate complexity and required context
3. Check which agents are available (idle or low-context)
4. Check which account has more capacity
5. Assign to best-fit agent on best-fit account
6. Monitor progress, re-assign if blocked
```

### 13.3 Cross-Agent Memory Sharing

Instead of isolated handoff files, a shared memory store:

```
~/.claude/shared-memory/
├── discoveries.json     # Key findings across all agents
├── blockers.json        # Current blockers (cross-referenced)
├── decisions.json       # User decisions and approvals
└── context-cache/       # Pre-computed context summaries
    ├── project-ncs.md
    ├── project-ayacucho.md
    └── infrastructure.md
```

### 13.4 Proactive Suggestions

After completing the audit, here are features that could enhance your workflow:

1. **Git PR Auto-Assignment** -- When a PR is ready, auto-assign reviewers and ping via Teams
2. **Dependency Graph** -- Track which agents depend on others' output (e.g., frontend waits for API changes)
3. **Session Templates** -- Pre-configured agent profiles: "frontend-dev", "devops", "code-review"
4. **Time-Based Scheduling** -- Run specific tasks at specific times (daily standup report, nightly test suite)
5. **Metrics Dashboard** -- Web UI showing agent performance, token usage, completion rates
6. **Smart Context Prefill** -- New sessions automatically receive relevant context from Agent Hub posts
7. **Rollback Mechanism** -- If a respawn goes wrong, restore the previous session state

---

## 14. Implementation Roadmap

### Phase 1: Critical Fixes (This Week)

| Priority | Task | Effort |
|----------|------|--------|
| P0 | Move credentials from config.env to .env.local | 30 min |
| P0 | Add teammate detection to auto-respawn.sh | 2 hours |
| P0 | Fix find-session.sh model reference (haiku 4.5) | 5 min |
| P1 | Add input sanitization to orchestrator.sh | 1 hour |
| P1 | Dynamic context window size detection in statusline.sh | 30 min |

### Phase 2: Account Management (This Week)

| Priority | Task | Effort |
|----------|------|--------|
| P1 | Create usage-tracker.sh for daily token logging | 2 hours |
| P1 | Create smart-rotate.sh for intelligent rotation | 3 hours |
| P1 | Add account prefix to session naming | 1 hour |
| P2 | Update Telegram message format with account info | 1 hour |
| P2 | Add weekly usage to statusline display | 30 min |

### Phase 3: Enhanced Handoffs (Next Week)

| Priority | Task | Effort |
|----------|------|--------|
| P1 | Create HANDOFF_V3.md template | 1 hour |
| P1 | Enhance handoff-log.sh with significance detection | 2 hours |
| P2 | Add PostToolUse hook for auto-logging | 2 hours |
| P2 | Add services/parameters tracking to template | 1 hour |

### Phase 4: TTS & Reporting (Next Week)

| Priority | Task | Effort |
|----------|------|--------|
| P2 | Add priority queue to TTS system | 2 hours |
| P2 | Create tts-batch.sh for coordinator digest | 3 hours |
| P2 | Add Telegram dashboard command (/dashboard) | 3 hours |
| P3 | Telegram voice message support (ffmpeg) | 4 hours |

### Phase 5: Advanced Features (Ongoing)

| Priority | Task | Effort |
|----------|------|--------|
| P3 | Enhanced reply parsing with cross-agent routing | 4 hours |
| P3 | Inline keyboard buttons for quick actions | 4 hours |
| P3 | Shared memory store for cross-agent context | 8 hours |
| P3 | Smart task assignment by claude-0 | 8 hours |
| P4 | Voice call briefings | 16 hours |

---

## Appendix A: Git Repository Status

```
Repository: git@github.com:gergokiss-work/claude-telegram-orchestrator.git
Branch:     master (single branch, no PRs)
Status:     Clean -- no uncommitted changes
Last Commit: 0583d90 Fix: Accept handoffs by filename OR modification time
Total Commits: 20+ (full history in single branch)
```

## Appendix B: Configuration Reference

| Config File | Key Settings |
|-------------|-------------|
| `handoff-config.json` | threshold: 60%, wait: 300s, excluded: [backend, frontend, ncs-frontend] |
| `config.env` | POLL_INTERVAL=5, MAX_SESSIONS=10, API_PORT=8765 |
| `settings.json` | SessionStart hook, Stop hook (sound + TTS + hub), statusline |

## Appendix C: Key Metrics

| Metric | Value |
|--------|-------|
| Total code | ~4,500 lines across 15+ files |
| Log entries | 2,139+ auto-respawn log lines |
| Respawn triggers | 160+ over 15 days |
| Typical respawn time | 20-60 seconds |
| Session capacity | Up to 10 concurrent (configurable) |
| Polling interval | 5 seconds |
| Context threshold | 60% of window |
| Handoff wait | 300 seconds max |

---

*Generated by claude-0 coordinator with 5 parallel research agents. All findings verified against source files.*
