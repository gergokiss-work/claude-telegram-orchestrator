#!/bin/bash
# ralph-task.sh - Launch autonomous task loops on Claude sessions
#
# Usage:
#   ralph-task.sh <session> "Task description"           # Start new task
#   ralph-task.sh <session> --from-file task.md          # Start from file
#   ralph-task.sh <session> --status                     # Check task status
#   ralph-task.sh <session> --complete                   # Mark task complete
#   ralph-task.sh <session> --cancel                     # Cancel task
#
# Integration:
#   - Uses existing watchdog.sh for monitoring (no duplicate loop)
#   - Uses existing inject-prompt.sh for prompts
#   - Task file in ~/.claude/handoffs/${SESSION}-task.md
#   - Claude updates checkboxes as it works
#   - Watchdog detects completion via RALPH_STATUS OR all boxes checked

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOFFS_DIR="$HOME/.claude/handoffs"
TASK_FILE_SUFFIX="-task.md"

mkdir -p "$HANDOFFS_DIR"

#
# Utility functions
#

log() {
    echo "[ralph-task] $1"
}

get_task_file() {
    local session=$1
    echo "$HANDOFFS_DIR/${session}${TASK_FILE_SUFFIX}"
}

task_exists() {
    local session=$1
    [[ -f "$(get_task_file "$session")" ]]
}

#
# Task file operations
#

create_task_file() {
    local session=$1
    local description=$2
    local task_file=$(get_task_file "$session")
    local timestamp=$(date '+%Y-%m-%d %H:%M')

    cat > "$task_file" << EOF
# Task: $description

**Session:** $session
**Created:** $timestamp
**Status:** IN_PROGRESS

## Checklist

<!-- Claude: Break down the task and check boxes as you complete them -->
- [ ] Understand requirements and explore codebase
- [ ] Plan implementation approach
- [ ] Implement the solution
- [ ] Test and verify
- [ ] Send summary (TTS + Telegram)

## Notes

<!-- Claude: Add notes, blockers, or questions here -->

---

## Task Protocol

When working on this task:
1. Check boxes as you complete each step
2. Add sub-tasks if needed (indented with 2 spaces)
3. When ALL boxes are checked, set EXIT_SIGNAL: true
4. If blocked, note the blocker and ask for help

## Current Status

RALPH_STATUS:
STATUS: IN_PROGRESS
EXIT_SIGNAL: false
WORK_TYPE: task
FILES_MODIFIED: 0
TASKS_REMAINING: 5
EOF

    log "Created task file: $task_file"
}

create_task_from_file() {
    local session=$1
    local source_file=$2
    local task_file=$(get_task_file "$session")

    if [[ ! -f "$source_file" ]]; then
        log "Error: Source file not found: $source_file"
        return 1
    fi

    cp "$source_file" "$task_file"

    # Ensure RALPH_STATUS block exists
    if ! grep -q "RALPH_STATUS:" "$task_file"; then
        cat >> "$task_file" << 'EOF'

---

## Current Status

RALPH_STATUS:
STATUS: IN_PROGRESS
EXIT_SIGNAL: false
WORK_TYPE: task
FILES_MODIFIED: 0
TASKS_REMAINING: 0
EOF
    fi

    log "Created task file from: $source_file"
}

#
# Task status parsing
#

parse_task_status() {
    local session=$1
    local task_file=$(get_task_file "$session")

    if [[ ! -f "$task_file" ]]; then
        echo "no_task"
        return
    fi

    # Count checkboxes
    local total=$(grep -cE "^\s*- \[[ x]\]" "$task_file" 2>/dev/null || echo "0")
    local done=$(grep -cE "^\s*- \[x\]" "$task_file" 2>/dev/null || echo "0")
    local pending=$((total - done))

    # Check RALPH_STATUS
    local exit_signal=$(grep -A5 "RALPH_STATUS:" "$task_file" | grep "EXIT_SIGNAL:" | sed 's/.*EXIT_SIGNAL:[[:space:]]*//' | tr -d ' ')
    local status=$(grep -A5 "RALPH_STATUS:" "$task_file" | grep "^STATUS:" | sed 's/.*STATUS:[[:space:]]*//' | tr -d ' ')

    # Determine overall status
    if [[ "$exit_signal" == "true" ]]; then
        echo "complete|$done/$total|exit_signal"
    elif [[ $total -gt 0 && $pending -eq 0 ]]; then
        echo "complete|$done/$total|all_checked"
    elif [[ "$status" == "COMPLETE" ]]; then
        echo "phase_complete|$done/$total|status_complete"
    else
        echo "in_progress|$done/$total|working"
    fi
}

#
# Prompt generation
#

generate_task_prompt() {
    local session=$1
    local task_file=$(get_task_file "$session")
    local description=$(head -1 "$task_file" | sed 's/^# Task: //')

    cat << EOF
🎯 **Autonomous Task Mode**

You have a task file at: $task_file

**Task:** $description

**Instructions:**
1. Read your task file: \`cat $task_file\`
2. Work through the checklist items
3. Check boxes as you complete them (edit the file)
4. Add sub-tasks if needed
5. When done, update RALPH_STATUS with EXIT_SIGNAL: true
6. Send summaries: TTS + Telegram

**Important:**
- Work autonomously until the task is complete
- Update the task file as you progress
- If blocked, note it in the file and ask for help
- Auto-respawn is DISABLED - work until done

Start by reading the task file and understanding the requirements.
EOF
}

#
# Commands
#

cmd_start() {
    local session=$1
    shift

    # Check if session exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        log "Error: Session $session does not exist"
        log "Available sessions: $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' | tr '\n' ' ')"
        return 1
    fi

    # Check for existing task
    if task_exists "$session"; then
        local status=$(parse_task_status "$session")
        log "Warning: Task already exists for $session (status: $status)"
        log "Use --cancel to remove it first, or --status to check progress"
        return 1
    fi

    # Handle --from-file or description
    if [[ "$1" == "--from-file" ]]; then
        create_task_from_file "$session" "$2" || return 1
    else
        local description="$*"
        if [[ -z "$description" ]]; then
            log "Error: No task description provided"
            log "Usage: ralph-task.sh <session> \"Task description\""
            return 1
        fi
        create_task_file "$session" "$description"
    fi

    # Generate and inject prompt
    local prompt=$(generate_task_prompt "$session")
    "$SCRIPT_DIR/inject-prompt.sh" "$session" "$prompt"

    # Add to watchdog if running
    if "$SCRIPT_DIR/watchdog.sh" status 2>/dev/null | grep -q "Running"; then
        "$SCRIPT_DIR/watchdog.sh" add "$session" 2>/dev/null
        log "Added $session to watchdog"
    else
        log "Tip: Start watchdog for monitoring: watchdog.sh start $session"
    fi

    # Send Telegram notification
    "$SCRIPT_DIR/send-summary.sh" --session "$session" "🎯 <b>Task Started</b>

<b>Session:</b> $session
<b>Task:</b> $(head -1 "$(get_task_file "$session")" | sed 's/^# Task: //')

Task file created. Working autonomously until complete."

    log "Task started on $session"
    log "Monitor: watchdog.sh status"
    log "Check: ralph-task.sh $session --status"
}

cmd_status() {
    local session=$1
    local task_file=$(get_task_file "$session")

    if [[ ! -f "$task_file" ]]; then
        log "No active task for $session"
        return 1
    fi

    local status=$(parse_task_status "$session")
    local state=$(echo "$status" | cut -d'|' -f1)
    local progress=$(echo "$status" | cut -d'|' -f2)
    local reason=$(echo "$status" | cut -d'|' -f3)

    local description=$(head -1 "$task_file" | sed 's/^# Task: //')
    local created=$(grep "^\*\*Created:\*\*" "$task_file" | sed 's/.*\*\*Created:\*\* //')

    echo "📋 Task Status: $session"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Task:     $description"
    echo "Created:  $created"
    echo "Progress: $progress checkboxes"
    echo "State:    $state ($reason)"
    echo ""
    echo "Checklist:"
    grep -E "^\s*- \[[ x]\]" "$task_file" | head -10

    local remaining=$(grep -cE "^\s*- \[ \]" "$task_file" 2>/dev/null | head -1 || echo "0")
    remaining=${remaining//[^0-9]/}  # Strip non-numeric
    [[ -z "$remaining" ]] && remaining=0
    if [[ $remaining -gt 10 ]]; then
        echo "  ... and $((remaining - 10)) more pending items"
    fi
}

cmd_complete() {
    local session=$1
    local task_file=$(get_task_file "$session")

    if [[ ! -f "$task_file" ]]; then
        log "No active task for $session"
        return 1
    fi

    # Update RALPH_STATUS to complete
    sed -i '' 's/STATUS: IN_PROGRESS/STATUS: COMPLETE/' "$task_file"
    sed -i '' 's/EXIT_SIGNAL: false/EXIT_SIGNAL: true/' "$task_file"

    # Archive the task file
    local archive_name="${session}-task-$(date '+%Y%m%d-%H%M').md"
    mv "$task_file" "$HANDOFFS_DIR/$archive_name"

    log "Task marked complete and archived: $archive_name"

    # Notify
    "$SCRIPT_DIR/send-summary.sh" --session "$session" "✅ <b>Task Manually Completed</b>

<b>Session:</b> $session
Task archived to $archive_name"
}

cmd_cancel() {
    local session=$1
    local task_file=$(get_task_file "$session")

    if [[ ! -f "$task_file" ]]; then
        log "No active task for $session"
        return 1
    fi

    # Archive with cancelled suffix
    local archive_name="${session}-task-$(date '+%Y%m%d-%H%M')-cancelled.md"
    mv "$task_file" "$HANDOFFS_DIR/$archive_name"

    log "Task cancelled and archived: $archive_name"
}

cmd_list() {
    echo "📋 Active Tasks"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local found=0
    for task_file in "$HANDOFFS_DIR"/*${TASK_FILE_SUFFIX}; do
        [[ ! -f "$task_file" ]] && continue
        found=1

        local session=$(basename "$task_file" "$TASK_FILE_SUFFIX")
        local status=$(parse_task_status "$session")
        local state=$(echo "$status" | cut -d'|' -f1)
        local progress=$(echo "$status" | cut -d'|' -f2)
        local description=$(head -1 "$task_file" | sed 's/^# Task: //')

        printf "%-12s %-15s %s\n" "$session" "[$progress] $state" "$description"
    done

    if [[ $found -eq 0 ]]; then
        echo "No active tasks"
    fi
}

cmd_loop() {
    local session=$1
    shift
    local max_loops=${1:-100}

    local task_file=$(get_task_file "$session")

    if [[ ! -f "$task_file" ]]; then
        log "No task file for $session. Create one first."
        return 1
    fi

    log "Starting RALPH worker loop for $session (max $max_loops loops)"
    "$SCRIPT_DIR/ralph-worker.sh" "$session" --task-file "$task_file" --max-loops "$max_loops"
}

cmd_worker_status() {
    local session=$1
    "$SCRIPT_DIR/ralph-worker.sh" "$session" --status
}

cmd_stop_worker() {
    local session=$1
    "$SCRIPT_DIR/ralph-worker.sh" "$session" --stop
}

cmd_help() {
    cat << 'EOF'
🔄 ralph-task.sh - Autonomous Task Loops

Usage:
  ralph-task.sh <session> "Task description"    Start new task (one-shot prompt)
  ralph-task.sh <session> --loop [max-loops]    Start task with RALPH worker loop
  ralph-task.sh <session> --from-file file.md   Start from existing file
  ralph-task.sh <session> --status              Check task progress
  ralph-task.sh <session> --worker-status       Check RALPH worker status
  ralph-task.sh <session> --stop-worker         Stop RALPH worker
  ralph-task.sh <session> --complete            Mark task manually complete
  ralph-task.sh <session> --cancel              Cancel and archive task
  ralph-task.sh --list                          List all active tasks

Modes:
  Default (no --loop):
    Creates task file, injects prompt once, watchdog monitors completion.
    Good for: Simple tasks, manual supervision.

  With --loop:
    Starts sophisticated RALPH worker that loops until task complete.
    Features: 3-state circuit breaker, rate limiting, exit detection.
    Good for: Complex multi-step tasks, autonomous operation.

How It Works:
  1. Creates task file: ~/.claude/handoffs/${SESSION}-task.md
  2. Without --loop: Injects prompt, watchdog monitors
  3. With --loop: Starts ralph-worker.sh for autonomous looping

Integration:
  - Uses watchdog.sh for monitoring (default mode)
  - Uses ralph-worker.sh for loop mode
  - Compatible with auto-respawn.sh

Examples:
  # Simple task (watchdog monitors)
  ralph-task.sh claude-5 "Fix the login bug"

  # Complex task (RALPH worker loop)
  ralph-task.sh claude-5 "Build user auth system" --loop 50

  # Check worker status
  ralph-task.sh claude-5 --worker-status

  # Stop worker
  ralph-task.sh claude-5 --stop-worker

Task File Format:
  Markdown checklist that Claude updates. Completion detected when:
  - EXIT_SIGNAL: true in RALPH_STATUS block, OR
  - All checkboxes [x] are checked
EOF
}

#
# Main
#

case "$1" in
    --list|-l)
        cmd_list
        ;;
    --help|-h|"")
        cmd_help
        ;;
    *)
        session=$1
        shift
        case "$1" in
            --status|-s)
                cmd_status "$session"
                ;;
            --complete|-c)
                cmd_complete "$session"
                ;;
            --cancel)
                cmd_cancel "$session"
                ;;
            --loop)
                shift
                cmd_loop "$session" "$@"
                ;;
            --worker-status)
                cmd_worker_status "$session"
                ;;
            --stop-worker)
                cmd_stop_worker "$session"
                ;;
            --from-file)
                cmd_start "$session" "$@"
                ;;
            *)
                cmd_start "$session" "$@"
                ;;
        esac
        ;;
esac
