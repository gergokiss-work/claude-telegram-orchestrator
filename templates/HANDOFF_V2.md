# Handoff: {SESSION_NAME}

**Created:** {TIMESTAMP}
**Directory:** {WORKING_DIR}
**Branch:** {GIT_BRANCH}
**Previous Handoff:** {PREVIOUS_FILE or "None"}

---

## 🎯 Mission
> One-liner: What is this agent trying to accomplish?

{CLEAR_GOAL_STATEMENT}

---

## 📍 Current State
**Status:** {IN_PROGRESS | BLOCKED | PAUSED | READY_FOR_REVIEW}
**Context Used:** {PERCENTAGE}%
**Last Action:** {WHAT_WAS_HAPPENING_WHEN_HANDOFF_TRIGGERED}

---

## 📜 Action Log

Chronological record of significant actions. **Be specific** - next agent needs to trace your steps.

| Time | Action | Result |
|------|--------|--------|
| HH:MM | `command or action` | outcome/finding |
| HH:MM | Read `path/to/file` | found X, learned Y |
| HH:MM | Edited `path/to/file:LINE` | changed Z |
| HH:MM | Ran `npm test` | 3 failures in auth module |

---

## 📁 Files Touched

### Read (for context)
- `path/to/file.ts` - why you read it
- `path/to/config.json` - what you learned

### Modified
- `path/to/file.ts:45-67` - what you changed and why
- `path/to/other.ts:12` - added X

### Created
- `path/to/new-file.ts` - purpose

### Deleted
- `path/to/old-file.ts` - why removed

---

## 🔧 Commands Executed

Important commands (not trivial ls/cat). Include outputs if relevant.

```bash
# What this does
$ actual command here
> key output lines (truncated if long)

# Another important command
$ npm run build
> Build failed: error in auth/index.ts:45
```

---

## 💡 Key Discoveries

Things the next agent MUST know:

1. **Finding:** Description
   - Evidence: where you found it
   - Implication: what it means

2. **Finding:** Description
   - Evidence: where you found it
   - Implication: what it means

---

## 🚧 Blockers / Open Questions

- [ ] Blocker: Description - what's needed to unblock
- [ ] Question: Needs clarification from user/team
- [ ] TODO: Deferred task

---

## ⏭️ Continuation Prompt

**Copy-paste this to continue the work:**

```
You are {SESSION_NAME} continuing from handoff {THIS_FILE}.

MISSION: {GOAL}

CURRENT STATE: {WHERE_WE_LEFT_OFF}

IMMEDIATE NEXT STEPS:
1. {SPECIFIC_ACTION_1}
2. {SPECIFIC_ACTION_2}
3. {SPECIFIC_ACTION_3}

KEY CONTEXT:
- {CRITICAL_FACT_1}
- {CRITICAL_FACT_2}

START BY: {EXACT_FIRST_ACTION}
```

---

## 🔗 Related Resources

- Handoffs: `{RELATED_HANDOFF_FILES}`
- Docs: `{RELEVANT_DOCS}`
- PRs/Issues: `{LINKS}`
