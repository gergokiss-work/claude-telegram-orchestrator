# [Project Name] - Progress Log

## Session: YYYY-MM-DD [Session Type]

### HH:MM - [Agent/Session] Started
- **Status:** [Current status description]
- **Context:** [Any relevant context from previous session]
- **Focus:** [What this session will focus on]

### Current State Assessment
- **Database:** [Status if applicable]
- **Services:** [Status of external services]
- **Git:** [Uncommitted changes, branch status]
- **Blockers:** [Any known issues]

---

## Milestone Log

| Time | Agent | Milestone | Notes |
|------|-------|-----------|-------|
| HH:MM | claude-X | [What was done] | [Additional details] |

---

## Session Summary

### Features Delivered
1. **[Feature Name]** - [Brief description]

### Technical Stats
- **Git Commits:** X commits this session
- **Lines Changed:** +X / -Y
- **Tests:** X passing, Y skipped

### Pending (Need User)
- [ ] [Action needed from user]

---

## How to Use This Template

### Getting Real Timestamps

**CRITICAL**: Never hallucinate timestamps. Always get real Mac time:

```bash
# Get current time for progress entries
date +"%H:%M"  # Output: 14:35

# Get current date for session headers
date +"%Y-%m-%d"  # Output: 2025-01-12

# Or use the context collector
bash .claude/scripts/context-collector.sh
```

### Session Entry Format

When starting a session:
```markdown
### 14:35 - claude-1 Started
- **Status:** Taking over from previous session
- **Context:** [Review last session's summary]
```

### Milestone Entry Format

After completing each significant task:
```markdown
| 14:42 | claude-1 | API endpoint created | /api/users with CRUD |
```

### Time Tracking Rules

1. **Run `date +"%H:%M"` before each timestamp entry**
2. **Never estimate or guess times**
3. **Log milestones as they happen, not retroactively**
4. **Use 24-hour format (HH:MM)**

### Session Types

- `Night Shift` - Overnight autonomous work
- `Morning Session` - Morning focused work
- `Afternoon Session` - Afternoon work
- `Quick Fix` - Brief targeted session
- `Review` - Code review or analysis session
