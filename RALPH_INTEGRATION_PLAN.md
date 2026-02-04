# RALPH Loop Integration Plan

## Overview

This document outlines how to incorporate [RALPH loops](https://github.com/frankbria/ralph-claude-code) (v0.10.1) into our Telegram Orchestrator system for enhanced autonomous operation.

**RALPH** = Autonomous AI development loop with intelligent exit detection, rate limiting, and circuit breaker patterns.

## Current Systems Comparison

| Feature | Our Orchestrator | RALPH |
|---------|------------------|-------|
| Session Management | tmux + inject-prompt | tmux + PROMPT.md |
| Task Tracking | Manual / handoffs | @fix_plan.md checkboxes |
| Exit Detection | None (manual) | Dual-condition gate |
| Circuit Breaker | None | 3-state (CLOSED/HALF_OPEN/OPEN) |
| Context Management | 50% threshold respawn | 24h session expiry |
| Rate Limiting | None | 100 calls/hour configurable |
| Response Analysis | Basic state detection | JSON parsing + semantic analysis |
| Stuck Detection | watchdog.sh patterns | Multi-line error matching |

## Integration Strategy

### Phase 1: Task Loop Mode for Workers (High Value)

**Goal:** Enable worker sessions (claude-1+) to run autonomous loops on complex tasks.

**Implementation:**

```bash
# New script: ~/.claude/scripts/ralph-task.sh
# Wraps RALPH loop for single task execution

ralph-task.sh claude-5 "Refactor the authentication module" \
  --max-loops 10 \
  --working-dir /path/to/project
```

**Components to Add:**
1. `ralph-task.sh` - Spawns RALPH-style loop for a specific task
2. `task-plan.md` - Per-task equivalent of @fix_plan.md
3. Task exit conditions:
   - All checkboxes complete
   - EXIT_SIGNAL: true from Claude
   - Circuit breaker opens
   - Max loops reached

**Files to Create:**
- `~/.claude/scripts/ralph-task.sh`
- `~/.claude/templates/task-plan.md`

### Phase 2: Circuit Breaker Enhancement (High Value)

**Goal:** Add RALPH's circuit breaker pattern to prevent runaway sessions.

**Current watchdog.sh detects:**
- `approval_prompt`, `plan_mode`, `quote_stuck`
- `low_context`, `dead`, `working`, `idle`

**Add RALPH-style circuit breaker:**

```bash
# Circuit breaker states
CB_STATE_FILE="~/.claude/handoffs/.circuit_breaker_${SESSION}"

# Thresholds (from RALPH)
CB_NO_PROGRESS_THRESHOLD=3      # 3 loops with no file changes
CB_SAME_ERROR_THRESHOLD=5       # 5 loops with repeated errors
CB_OUTPUT_DECLINE_THRESHOLD=70  # 70% output decline
```

**Integration Points:**
- Enhance `watchdog.sh` with circuit breaker logic
- Add `get_circuit_state()`, `record_loop_result()`, `should_halt_execution()`
- Integrate with auto-respawn: open circuit → reset session

**Files to Modify:**
- `~/.claude/telegram-orchestrator/watchdog.sh` - Add circuit breaker
- `~/.claude/scripts/auto-respawn.sh` - Reset circuit on respawn

### Phase 3: Intelligent Exit Detection (Medium Value)

**Goal:** Prevent premature exits when Claude reports "done" but has more work.

**RALPH's Dual-Condition Gate:**
```
EXIT requires BOTH:
1. completion_indicators >= 2 (heuristic detection)
2. EXIT_SIGNAL: true (explicit confirmation)
```

**Implementation for Telegram:**

```bash
# Add to response analysis
analyze_response() {
    local output="$1"

    # Look for RALPH_STATUS block in Claude output
    # RALPH_STATUS:
    # STATUS: IN_PROGRESS|COMPLETE
    # EXIT_SIGNAL: true|false
    # WORK_TYPE: feature|bugfix|test|docs

    local exit_signal=$(grep -A5 "RALPH_STATUS" "$output" | grep "EXIT_SIGNAL" | cut -d: -f2 | tr -d ' ')
    local completion_count=$(grep -cE "done|complete|finished|all tasks" "$output")

    # Only exit if BOTH conditions met
    if [[ $completion_count -ge 2 && "$exit_signal" == "true" ]]; then
        return 0  # Safe to exit
    fi
    return 1  # Continue working
}
```

**Teach Claude the RALPH_STATUS format:**
Add to handoff prompts and continuation prompts:

```markdown
## Task Completion Protocol

When finishing work, include a status block:

RALPH_STATUS:
STATUS: COMPLETE|IN_PROGRESS
EXIT_SIGNAL: true|false
WORK_TYPE: feature|bugfix|test|docs
FILES_MODIFIED: N

Set EXIT_SIGNAL: true ONLY when ALL tasks are done.
```

### Phase 4: Enhanced Response Analysis (Medium Value)

**Goal:** Parse Claude's JSON output for structured decision-making.

**RALPH's JSON parsing:**
```bash
# From response_analyzer.sh
parse_json_response() {
    local json="$1"

    # Extract fields
    local status=$(jq -r '.status // "unknown"' <<< "$json")
    local exit_signal=$(jq -r '.exit_signal // false' <<< "$json")
    local work_type=$(jq -r '.work_type // "unknown"' <<< "$json")
    local files_modified=$(jq -r '.files_modified // 0' <<< "$json")
}
```

**Integration:**
Add response analysis to `watchdog.sh` state detection:

```bash
# Enhanced detect_state()
detect_state() {
    local session=$1
    local output=$(tmux capture-pane -t "$session" -p)

    # Check for RALPH_STATUS block
    if echo "$output" | grep -q "RALPH_STATUS"; then
        local status=$(echo "$output" | grep -A5 "RALPH_STATUS" | grep "STATUS" | cut -d: -f2 | tr -d ' ')
        case $status in
            "COMPLETE") echo "complete" ;;
            "IN_PROGRESS") echo "working" ;;
            *) # Fall back to existing detection
        esac
    fi

    # ... existing detection logic
}
```

### Phase 5: Rate Limiting (Low Priority)

**Goal:** Prevent API overuse in long-running operations.

**RALPH's approach:**
- 100 calls/hour default
- Per-hour reset with countdown
- Hourly file-based tracking

**For our system:**
Consider global rate limiting across all sessions:

```bash
# ~/.claude/scripts/rate-limit.sh
CALL_COUNT_FILE="$HOME/.claude/handoffs/.call_count"
MAX_CALLS_PER_HOUR=${MAX_CALLS_PER_HOUR:-500}  # Higher for multi-session

can_make_call() {
    local current_hour=$(date +%Y%m%d%H)
    # ... tracking logic
}
```

**Note:** Lower priority because:
- Our sessions are interactive (not continuous loops)
- Context threshold (50%) naturally limits activity
- Could add if we see API overuse issues

## Integration Architecture

### New Directory Structure

```
~/.claude/
├── scripts/
│   ├── ralph-task.sh          # NEW: Run RALPH-style task loop
│   ├── circuit-breaker.sh     # NEW: Circuit breaker library
│   └── response-analyzer.sh   # NEW: Response analysis library
├── templates/
│   ├── task-plan.md           # NEW: Per-task checklist template
│   └── RALPH_STATUS.md        # NEW: Status block format for Claude
└── telegram-orchestrator/
    ├── watchdog.sh            # MODIFY: Add circuit breaker
    └── lib/
        └── ralph-utils.sh     # NEW: Shared RALPH utilities
```

### Message Flow with RALPH Integration

```
User (Telegram)
    ↓
orchestrator.sh
    ↓
┌─────────────────────────────────────────┐
│ Simple Task          │ Complex Task     │
│   ↓                  │    ↓             │
│ inject_input()       │ ralph-task.sh    │
│   ↓                  │    ↓             │
│ One-shot response    │ Autonomous Loop  │
│                      │    ↓             │
│                      │ Circuit Breaker  │
│                      │    ↓             │
│                      │ Exit Detection   │
└─────────────────────────────────────────┘
    ↓
send-summary.sh (with RALPH_STATUS)
    ↓
User (Telegram)
```

## Implementation Priority

| Phase | Feature | Value | Effort | Priority |
|-------|---------|-------|--------|----------|
| 1 | Task Loop Mode | High | Medium | 🔴 P1 |
| 2 | Circuit Breaker | High | Low | 🔴 P1 |
| 3 | Exit Detection | Medium | Low | 🟡 P2 |
| 4 | Response Analysis | Medium | Medium | 🟡 P2 |
| 5 | Rate Limiting | Low | Low | 🟢 P3 |

## Quick Wins (Can Implement Now)

### 1. Add RALPH_STATUS Protocol to Handoffs

Update `~/.claude/handoff-prompt.md`:

```markdown
## Status Block (Required)

Before completing any task, include:

RALPH_STATUS:
STATUS: COMPLETE|IN_PROGRESS
EXIT_SIGNAL: true|false
WORK_TYPE: feature|bugfix|test|docs|research
FILES_MODIFIED: N
TASKS_REMAINING: N

Set EXIT_SIGNAL: true ONLY when ALL assigned tasks are done.
```

### 2. Add Basic Circuit Breaker to Watchdog

In `watchdog.sh`, add simple stagnation detection:

```bash
check_progress() {
    local session=$1
    local progress_file="$STATE_DIR/${session}_progress"

    # Count file changes
    local files_changed=$(tmux send-keys -t "$session" "git diff --name-only 2>/dev/null | wc -l" Enter; sleep 1; tmux capture-pane -t "$session" -p | tail -2 | head -1)

    # Load last count
    local last_count=$(cat "$progress_file" 2>/dev/null || echo "0")

    # Track no-progress iterations
    local no_progress_file="$STATE_DIR/${session}_no_progress"
    local no_progress=$(cat "$no_progress_file" 2>/dev/null || echo "0")

    if [[ "$files_changed" == "$last_count" ]]; then
        no_progress=$((no_progress + 1))
        if [[ $no_progress -ge 3 ]]; then
            log "[$session] Circuit breaker: No progress for 3 cycles"
            return 1  # Trigger intervention
        fi
    else
        no_progress=0
    fi

    echo "$files_changed" > "$progress_file"
    echo "$no_progress" > "$no_progress_file"
    return 0
}
```

### 3. Teach Agents the RALPH Protocol

Add to `~/.claude/CLAUDE.md`:

```markdown
## RALPH Task Protocol

When completing tasks, include a status block in your response:

\`\`\`
RALPH_STATUS:
STATUS: IN_PROGRESS
EXIT_SIGNAL: false
WORK_TYPE: feature
FILES_MODIFIED: 3
TASKS_REMAINING: 2
\`\`\`

**Rules:**
- Set EXIT_SIGNAL: true ONLY when all assigned work is complete
- Use STATUS: COMPLETE for phases, EXIT_SIGNAL: true for full completion
- This prevents premature termination during multi-phase work
```

## Migration Path

### Step 1: Install RALPH (Reference)
```bash
cd ~/work/gergo/ralph-claude-code
./install.sh
```

### Step 2: Port Libraries
Copy and adapt RALPH's library components:
- `lib/circuit_breaker.sh` → `~/.claude/scripts/circuit-breaker.sh`
- `lib/response_analyzer.sh` → `~/.claude/scripts/response-analyzer.sh`
- `lib/date_utils.sh` → Merge into existing scripts

### Step 3: Integrate with Watchdog
Modify `watchdog.sh` to use circuit breaker:
```bash
source ~/.claude/scripts/circuit-breaker.sh

# In check loop
if should_halt_execution "$session"; then
    handle_circuit_open "$session"
fi
```

### Step 4: Add Task Loop Command
Create `/task` Telegram command:
```
/task claude-5 Implement user authentication module
```

Triggers `ralph-task.sh` with:
- Task-specific @fix_plan.md
- Circuit breaker monitoring
- Exit detection
- Telegram progress updates

## Testing Plan

1. **Unit Tests:**
   - Circuit breaker state transitions
   - Exit detection logic
   - Response parsing

2. **Integration Tests:**
   - Task loop completion
   - Circuit breaker activation/recovery
   - Auto-respawn with circuit state

3. **Manual Tests:**
   - Run 10-loop task on worker session
   - Verify circuit breaker triggers on stagnation
   - Verify EXIT_SIGNAL prevents premature exit

## References

- [RALPH Repository](https://github.com/frankbria/ralph-claude-code)
- [Geoffrey Huntley's Ralph Technique](https://ghuntley.com/ralph/)
- Local clone: `~/work/gergo/ralph-claude-code/`

---

## Critique & Refinements

*Added: 2026-01-22 16:30 | Reviewer: Fresh claude-0 instance*

### 1. Missing RALPH Features

The original plan captures the high-level concepts well but misses several valuable RALPH features:

| Feature | RALPH Implementation | Plan Status | Value |
|---------|---------------------|-------------|-------|
| **Session ID Continuity** | `--continue` flag + `.ralph_session` file | ❌ Not mentioned | High - prevents context loss across loops |
| **Structured Response File** | `.ralph/.response_analysis` JSON | ⚠️ Partial (Phase 4) | High - enables programmatic decisions |
| **Checkbox Task Tracking** | `@fix_plan.md` with `[x]` parsing | ❌ Not mentioned | Medium - automatic progress detection |
| **Safety Circuit Breaker** | Force exit after 5 consecutive completion indicators | ❌ Not mentioned | High - prevents runaway "almost done" loops |
| **Session History** | Last 50 transitions in `.ralph_session_history` | ❌ Not mentioned | Low - debugging aid |
| **Two-Stage Error Filtering** | JSON field filtering + actual error detection | ⚠️ Mentioned but not detailed | Medium - reduces false positives |

**Recommendation:** Add Session ID Continuity and Safety Circuit Breaker to Phase 2.

### 2. Priority Reassessment

| Phase | Original Priority | Recommended | Rationale |
|-------|------------------|-------------|-----------|
| 1. Task Loop Mode | 🔴 P1 | 🟡 P2 | Over-engineered for first iteration |
| 2. Circuit Breaker | 🔴 P1 | 🔴 **P0** | Foundational - other features depend on it |
| 3. Exit Detection | 🟡 P2 | 🔴 **P1** | Prevents wasted API calls + premature exits |
| 4. Response Analysis | 🟡 P2 | 🟡 P2 | Correct |
| 5. Rate Limiting | 🟢 P3 | 🟢 P3 | Correct - context threshold naturally limits |

**Key Insight:** Circuit breaker should be P0 because:
- Our watchdog already detects stuck states but lacks the circuit breaker pattern
- RALPH's 3-state model (CLOSED → HALF_OPEN → OPEN) enables graceful recovery
- Without it, other phases (exit detection, task loops) lack a safety net

### 3. Integration Challenges Not Addressed

#### 3.1 Structural Mismatch
```
RALPH assumes:                    We have:
───────────────────────────────   ─────────────────────────
Single project focus              Multi-session orchestration
.ralph/ folder per project        Arbitrary working directories
PROMPT.md drives each loop        Telegram messages drive tasks
```

**Challenge:** RALPH's `@fix_plan.md` checkbox tracking assumes a single project. Our sessions work across multiple repos.

**Solution:** Create session-specific task files: `~/.claude/handoffs/${SESSION}-tasks.md`

#### 3.2 Session Lifetime Conflict
```
RALPH: 24-hour session expiry
Ours:  50% context threshold (typically 30-60 minutes)
```

**Challenge:** RALPH's session ID is meant to persist across loops. Our respawn kills the session.

**Solution:** Preserve session ID across respawn in handoff file. New instance reads and continues session.

#### 3.3 CLI Compatibility
```
RALPH uses:                       We use:
─────────────────────────────     ─────────────────────────
claude --output-format json       inject-prompt.sh (paste text)
--continue flag                   tmux send-keys
Structured response parsing       tmux capture-pane
```

**Challenge:** Our `inject-prompt.sh` doesn't invoke Claude CLI directly - it pastes into a running session.

**Solution:** Parse RALPH_STATUS from `tmux capture-pane` output instead of JSON. The status block approach works regardless of invocation method.

#### 3.4 Coordinator vs Worker Model
RALPH has no coordinator concept - each project is independent.

**Challenge:** How does circuit breaker state coordinate across claude-0 (coordinator) and claude-N (workers)?

**Solution:** Per-session circuit breaker state files: `~/.claude/handoffs/.circuit_${SESSION}`

### 4. Minimum Viable Implementation (MVI)

**Goal:** Get value in one session of work, not a multi-week project.

#### MVI Scope (Do First)

```bash
# 1. Add circuit breaker to watchdog.sh (2 hours)
# Already has: detect_state(), fix_stuck_state()
# Add: circuit_state(), should_halt_execution(), record_loop_result()

# 2. RALPH_STATUS protocol in CLAUDE.md (30 min)
# Teach agents to output status blocks

# 3. Status block parsing in watchdog.sh (1 hour)
# Extract EXIT_SIGNAL from tmux capture-pane output
```

#### MVI Deferred (Do Later)

- `ralph-task.sh` wrapper (Phase 1) - complexity without circuit breaker is risky
- Full response analysis (Phase 4) - RALPH_STATUS parsing is sufficient for MVI
- Rate limiting (Phase 5) - not needed with context threshold

### 5. Revised Implementation Order

```
Week 1: Foundation
├── Day 1-2: Circuit breaker in watchdog.sh
│   ├── Add CB_STATE tracking per session
│   ├── Add cb_record_result() after each cycle
│   └── Add cb_should_halt() before force_push()
│
├── Day 3: RALPH_STATUS Protocol
│   ├── Update CLAUDE.md with status block format
│   ├── Update handoff-prompt.md
│   └── Add to auto-respawn continuation prompt
│
└── Day 4-5: Exit Detection
    ├── Parse RALPH_STATUS from capture output
    ├── Implement dual-condition gate
    └── Test with manual sessions

Week 2: Enhancement (if Week 1 proves value)
├── Session continuity across respawn
├── Checkbox task tracking
└── Full response analysis
```

### 6. Concrete First Steps

**Step 1: Create circuit-breaker.sh library**

```bash
#!/bin/bash
# ~/.claude/scripts/circuit-breaker.sh

CB_STATE_DIR="$HOME/.claude/handoffs/.circuits"
mkdir -p "$CB_STATE_DIR"

# States
CB_CLOSED="CLOSED"      # Normal operation
CB_HALF_OPEN="HALF_OPEN" # Testing after failure
CB_OPEN="OPEN"          # Halted, needs intervention

# Thresholds
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_RECOVERY_SUCCESS=2    # Successes needed in HALF_OPEN to close

cb_get_state() {
    local session=$1
    cat "$CB_STATE_DIR/${session}_state" 2>/dev/null || echo "$CB_CLOSED"
}

cb_set_state() {
    local session=$1
    local state=$2
    echo "$state" > "$CB_STATE_DIR/${session}_state"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $state" >> "$CB_STATE_DIR/${session}_history"
}

cb_record_result() {
    local session=$1
    local had_progress=$2  # true/false
    local had_error=$3     # true/false

    # Implementation: increment/reset counters, transition states
    # See RALPH lib/circuit_breaker.sh for full logic
}

cb_should_halt() {
    local session=$1
    [[ "$(cb_get_state "$session")" == "$CB_OPEN" ]]
}
```

**Step 2: Add to watchdog.sh daemon loop**

```bash
# In cmd_daemon(), after state detection:
source ~/.claude/scripts/circuit-breaker.sh

for session in $instances; do
    # Check circuit breaker FIRST
    if cb_should_halt "$session"; then
        log "[$session] Circuit OPEN - skipping (needs intervention)"
        continue
    fi

    # ... existing state detection ...

    # Record result for circuit breaker
    local had_progress=$(check_file_changes "$session")  # New function
    local had_error=$(echo "$state" | grep -qE "stuck|error" && echo "true" || echo "false")
    cb_record_result "$session" "$had_progress" "$had_error"
done
```

**Step 3: Add RALPH_STATUS to CLAUDE.md**

Already well-defined in Quick Wins section - just needs to be added.

### 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Circuit breaker too aggressive | Medium | High - stops productive work | Tune thresholds, start conservative (5 no-progress cycles) |
| RALPH_STATUS not consistently output | High | Medium - falls back to heuristics | Train in CLAUDE.md, remind in handoffs |
| State file corruption | Low | Medium - false circuit opens | Add validation, backup state |
| Coordinator circuit open blocks all work | Medium | High | Exclude claude-0 from circuit breaker or use separate thresholds |

### 8. Success Metrics

After MVI implementation, track:

1. **False exits reduced:** Count premature completions before/after EXIT_SIGNAL gate
2. **Stuck loops caught:** Circuit breaker activations vs manual interventions
3. **API efficiency:** Calls wasted on stuck/complete sessions
4. **Recovery time:** Time from circuit OPEN to productive work

---

## Fresh Instance Review (claude-5, 2026-01-22 16:22)

The critique above is solid. Here's what I'd refine further:

### Core Observation: Scope Creep Risk

The critique still proposes a "Week 1 / Week 2" timeline and creating new library files. This is scope creep from the original "Quick Wins" goal.

**True MVP (2 hours, no new files):**

1. **CLAUDE.md update** (10 min) - Add RALPH_STATUS section
2. **watchdog.sh modification** (1.5 hr) - Add inline circuit breaker + EXIT_SIGNAL parsing
3. **Test manually** (20 min) - Verify with one session

### Concrete Inline Circuit Breaker (No New Files)

Add directly to `watchdog.sh`:

```bash
# === CIRCUIT BREAKER (inline) ===
STATE_DIR="$HOME/.claude/handoffs/.session-state"
mkdir -p "$STATE_DIR"

cb_check() {
    local session=$1
    local state_file="$STATE_DIR/${session}.cb"

    # Read current no-progress count
    local no_prog=$(cat "$state_file" 2>/dev/null || echo "0")

    # Check for progress (any recent file changes via git)
    local changes=$(tmux capture-pane -t "$session" -p -S -50 | grep -c "✔\|modified:\|Created\|Edited")

    if [[ $changes -eq 0 ]]; then
        no_prog=$((no_prog + 1))
    else
        no_prog=0
    fi

    echo "$no_prog" > "$state_file"

    # Return 1 (halt) if threshold exceeded
    [[ $no_prog -ge 3 ]] && return 1
    return 0
}

cb_reset() {
    local session=$1
    rm -f "$STATE_DIR/${session}.cb"
}
```

### EXIT_SIGNAL Parsing (Inline)

```bash
# Add to existing detect_state() function
parse_ralph_status() {
    local output="$1"

    # Check for EXIT_SIGNAL: true
    if echo "$output" | grep -qE "EXIT_SIGNAL:\s*true"; then
        echo "exit_true"
        return
    fi

    # Check for STATUS: COMPLETE without EXIT_SIGNAL (partial completion)
    if echo "$output" | grep -qE "STATUS:\s*COMPLETE" && ! echo "$output" | grep -qE "EXIT_SIGNAL:\s*true"; then
        echo "phase_complete"
        return
    fi

    echo "working"
}
```

### What The Previous Critique Missed

1. **Coordinator should be exempt** - claude-0 handles Telegram routing, not development loops. Circuit breaker makes no sense for it.

2. **HALF_OPEN complexity is unnecessary** - RALPH's 3-state model is for long-running autonomous loops. Our sessions are supervised via Telegram. Simple OPEN/CLOSED is sufficient.

3. **File change detection is unreliable** - tmux capture-pane can miss rapid changes. Better proxy: look for Claude's "✔" completion indicators in output.

### Recommended Action

Don't follow the "Week 1 / Week 2" plan. Instead:

```bash
# Today: Minimal changes to existing files
1. Edit ~/.claude/CLAUDE.md - Add RALPH_STATUS protocol (10 min)
2. Edit watchdog.sh - Add cb_check() inline (45 min)
3. Edit watchdog.sh - Add parse_ralph_status() inline (30 min)
4. Test with one stuck session (15 min)
```

**That's it.** If this works, iterate. If not, we learned something without building a complex system.

---

*Fresh review completed: 2026-01-22 16:22 | Version: 1.2*
*Reviewer: claude-5 (auto-respawned instance)*
