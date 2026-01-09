# Telegram Summary Format Template

When sending summaries via `send-summary.sh`, **ALWAYS** use this format for readability.

## Format Structure

```
{STATUS_EMOJI} <b>{Status Title}</b>

🎯 <b>Request:</b> Brief description of what was asked

📋 <b>Result:</b>
• Key point 1
• Key point 2
• Key point 3

⚠️ <b>Blockers:</b> (only if applicable)
• Issue description

💡 <i>Next steps or helpful notes</i>
```

## Status Emojis

| Emoji | Meaning |
|-------|---------|
| ✅ | Task completed successfully |
| ⏳ | In progress / waiting |
| ❌ | Failed / error occurred |
| 💡 | Information / clarification |
| 🔧 | Code/config changes made |
| ⚠️ | Warning / needs attention |

## Section Emojis

| Emoji | Section |
|-------|---------|
| 🎯 | Request / Goal |
| 📋 | Result / Output |
| ⚠️ | Blockers / Warnings |
| 💡 | Tips / Next steps |
| 📁 | Files changed |
| 🔍 | Investigation findings |
| ❓ | Questions for user |

## HTML Formatting (supported)

- `<b>bold</b>` - for headers and emphasis
- `<i>italic</i>` - for notes and tips
- `<code>inline code</code>` - for commands, filenames
- `<pre>code block</pre>` - for multi-line code

## Examples

### Completed Task
```
✅ <b>Task Complete</b>

🎯 <b>Request:</b> Fix login bug

📋 <b>Result:</b>
• Fixed token validation in <code>auth.ts:45</code>
• Added expiry check
• Tests pass

💡 <i>Deployed to staging</i>
```

### In Progress
```
⏳ <b>Working</b>

🎯 <b>Request:</b> Refactor database layer

📋 <b>Progress:</b>
• Analyzed current structure
• Created migration plan

💡 <i>ETA: ~30 min remaining</i>
```

### Error/Failed
```
❌ <b>Failed</b>

🎯 <b>Request:</b> Deploy to production

📋 <b>Issue:</b>
• Build failed - missing dependency
• Error: <code>Module not found: xyz</code>

⚠️ <b>Blocker:</b> Need to install xyz package

❓ <i>Should I install it and retry?</i>
```

### Information/Clarification
```
💡 <b>Clarification</b>

🎯 <b>Question:</b> How does X work?

📋 <b>Answer:</b>
• Point 1 explanation
• Point 2 explanation

💡 <i>See docs at ~/.claude/docs/x.md</i>
```

## Rules

1. **Always use the status emoji + bold title** as the first line
2. **Keep it scannable** - user is on mobile, use bullets
3. **Include actual data** - error messages, file paths, counts
4. **Be complete** - user can't see the Mac screen
5. **Ask questions** when blocked - use ❓ emoji
