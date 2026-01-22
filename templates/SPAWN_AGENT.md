# Agent Spawn Template

Use this when spawning a new Claude agent session.

## Spawn Command

```bash
# Create new tmux session with Claude
SESSION="claude-XX"  # Replace XX with number
WORKING_DIR="/path/to/project"

tmux new-session -d -s "$SESSION" -c "$WORKING_DIR" "claude --dangerously-skip-permissions"
sleep 3

# Inject initial prompt
~/.claude/telegram-orchestrator/inject-prompt.sh "$SESSION" "$(cat << 'PROMPT'
# Your Assignment

**Session:** claude-XX
**Working Directory:** /path/to/project
**Task:** [Describe the task]

## Context Awareness (CRITICAL)

**Threshold is 50%.** Check context BEFORE starting each new task:
```bash
~/.claude/scripts/check-context.sh
```

**Rules:**
- **<40%:** OK to start new tasks
- **40-49%:** Only start small tasks, consider if next task fits
- **>=50%:** Do NOT start new tasks - complete current work and hand off

Before each TODO item, run the check. If at/near threshold:
1. Mark remaining TODOs as "not started" in your summary
2. Write handoff immediately:
   `~/.claude/handoffs/$(tmux display-message -p '#S')-$(date '+%Y-%m-%d-%H%M').md`

## Reporting (MANDATORY)

After completing work or before stopping:
```bash
# TTS (user nearby)
~/.claude/scripts/tts-write.sh "1-2 sentence summary"

# Telegram (user away)
~/.claude/telegram-orchestrator/send-summary.sh --session $(tmux display-message -p '#S') "formatted message"
```

## Your Task

[Detailed task description here]

## Success Criteria

- [ ] Criterion 1
- [ ] Criterion 2

Start by reading any relevant files, then proceed with the task.
PROMPT
)"
```

## Quick Spawn (Copy-Paste)

Replace `XX`, `WORKING_DIR`, and task description:

```bash
SESSION="claude-XX" && WORKING_DIR="/Users/gergokiss/work/project" && \
tmux new-session -d -s "$SESSION" -c "$WORKING_DIR" "claude --dangerously-skip-permissions" && \
sleep 3 && \
~/.claude/telegram-orchestrator/inject-prompt.sh "$SESSION" "
**Session:** $SESSION
**Working Dir:** $WORKING_DIR
**Task:** [YOUR TASK HERE]

## Context Rules
Check \`~/.claude/scripts/check-context.sh\` before each task.
<40%=OK, 40-49%=small tasks only, >=50%=hand off NOW

## Reporting
TTS: \`~/.claude/scripts/tts-write.sh \"summary\"\`
Telegram: \`~/.claude/telegram-orchestrator/send-summary.sh --session \$(tmux display-message -p '#S') \"msg\"\`

Start working.
"
```
