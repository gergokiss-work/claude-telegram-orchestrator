---
description: Read and send Microsoft Teams messages as Gergő
---

# Teams Messaging

Read conversations, find chats, and reply to Teams messages on behalf of Kiss Gergő via the n8n + MS Graph API integration.

## Usage

```
/teams read <person_name>              Read recent messages from a chat with someone
/teams read <chat_id>                  Read messages from a specific chat ID
/teams find <search_term>              Find chats by person name or topic
/teams send <person_name> <message>    Reply to a chat with someone
/teams send-to <email> <message>       Send a 1:1 message by email address
/teams list                            List recent chats
/teams watch [chat_id]                 Watch a chat for replies (auto-resume when reply arrives)
/teams unwatch                         Cancel your active watch
/teams watches                         List all active watches across sessions
```

If `$ARGUMENTS` is empty, ask the user what they want to do.

## Process

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the action:

- First word = command (`read`, `find`, `send`, `send-to`, `list`)
- If it looks like a Teams chat link (`https://teams.microsoft.com/...`), extract the chat context and treat as a `read` command
- If no recognized command, treat the whole argument as a `find` query

### Step 2: Resolve Chat Target

For commands that need a chat (read, send):

**If a chat ID is provided** (starts with `19:` and contains `@thread.v2`):
- Use it directly

**If a person's name is provided:**
1. Run: `~/.claude/scripts/teams-api.sh find-chats "<name>"`
2. Parse the JSON results
3. If multiple matches, show the user a list and ask which one
4. If one match, use that chat ID
5. If no match, tell the user and suggest trying a different name

**If a Teams link is provided:**
- Extract any identifiable info (chat ID, message ID) from the URL parameters
- If the link contains a chat context, use it for `read-chat`

### Step 3: Execute Action

#### `list` — List Recent Chats
```bash
~/.claude/scripts/teams-api.sh list-chats 20
```
Parse the JSON and display a clean table:
- Chat type (1:1 / group)
- Members or topic
- Last message preview + time

#### `find <search>` — Find Chats
```bash
~/.claude/scripts/teams-api.sh find-chats "<search_term>"
```
Display matching chats with their IDs, members, and type.

#### `read <target>` — Read Messages
```bash
~/.claude/scripts/teams-api.sh read-chat "<chat_id>" 15
```
Display messages in chronological order (oldest first):
```
[14:35] Kovacsevics András: Message text here...
[14:38] Somkuti András: Reply text here...
```

If there are attachments, note them: `📎 filename.txt (content-type)`

#### `send <target> <message>` — Send a Message
1. Resolve the chat ID (via find-chats if name given)
2. Format the message as HTML:
   - Convert markdown to HTML (`**bold**` → `<b>bold</b>`, etc.)
   - Preserve line breaks as `<br>`
3. **ALWAYS append signature:** `<br><br>🤖 <i>Küldve Gergő AI asszisztense által</i>`
4. **Show the user the message before sending** and ask for confirmation
5. Send:
```bash
~/.claude/scripts/teams-api.sh send "<chat_id>" "<html_message>"
```

#### `send-to <email> <message>` — Send by Email
1. Format message as HTML with signature (same as `send`)
2. **Show the user the message before sending** and ask for confirmation
3. Send:
```bash
~/.claude/scripts/teams-api.sh send-to "<email>" "<html_message>"
```

#### After any `send` or `send-to` — Offer Watch
After a successful send, the response includes `chatId` and `messageTime`. Offer:
> "Want me to monitor for replies? I'll resume automatically when they respond."

If yes, register a watch:
```bash
SESSION=$(tmux display-message -p '#S')
~/.claude/telegram-orchestrator/scripts/teams-watch.sh register \
  --session "$SESSION" \
  --chat-id "<chatId_from_send_response>" \
  --last-msg-time "<messageTime_from_send_response>" \
  --original-msg "<the message you sent>" \
  --timeout 24h
```

Then ensure the daemon is running:
```bash
~/.claude/telegram-orchestrator/scripts/teams-watch-daemon.sh start
```

Report: "Watch registered. I'll resume when a reply arrives (24h timeout)."

#### `watch [chat_id]` — Register a Watch
If no chat_id provided, use the last chat you interacted with in this session.
```bash
SESSION=$(tmux display-message -p '#S')
~/.claude/telegram-orchestrator/scripts/teams-watch.sh register \
  --session "$SESSION" \
  --chat-id "<chat_id>" \
  --last-msg-time "<current_iso_time>" \
  --timeout 24h
~/.claude/telegram-orchestrator/scripts/teams-watch-daemon.sh start
```

#### `unwatch` — Cancel Your Watch
```bash
SESSION=$(tmux display-message -p '#S')
~/.claude/telegram-orchestrator/scripts/teams-watch.sh unregister --session "$SESSION"
```

#### `watches` — List All Active Watches
```bash
~/.claude/telegram-orchestrator/scripts/teams-watch.sh list
```

### Step 4: Display Results

Format all output for readability:
- Clean up HTML entities (`&nbsp;`, `&lt;`, etc.)
- Strip HTML tags from message bodies
- Show timestamps in local time if possible
- For long messages, show first 200 chars with "..." indicator

## Important Guidelines

1. **Always use the signature** — Every sent message must end with `🤖 <i>Küldve Gergő AI asszisztense által</i>`
2. **Confirm before sending** — Show the formatted message and ask "Send this?" before actually sending. NEVER send without confirmation unless the user explicitly said to skip confirmation.
3. **HTML content type** — All messages use `contentType: html`. Convert any markdown formatting.
4. **Email domain** — NETLOCK emails use `@netlock.hu` (not .com). Somkuti uses `@netlock.com`.
5. **Hungarian names** — Display names are in Hungarian order (Family Given). Search works with either part.
6. **Chat ID format** — Full chat IDs look like: `19:abc123...@thread.v2`
7. **Rate limiting** — Each operation creates/destroys an n8n workflow. Don't run more than ~5 operations in quick succession.
8. **Error handling** — If the n8n workflow fails (empty response, error JSON), report the error clearly and suggest checking if the n8n instance is running.

## Known Contacts

| Name | Email | Notes |
|------|-------|-------|
| Molnár Dávid | molnar.david@netlock.hu | |
| Kovacsevics András | kovacsevics.andras@netlock.hu | |
| Somkuti András | andras.somkuti@netlock.com | Note: @netlock.com |
| Penk Richárd | penk.richard@netlock.hu | |

## Supported HTML in Teams

- `<b>`, `<strong>` — Bold
- `<i>`, `<em>` — Italic
- `<br>` — Line break
- `<code>` — Inline code
- `<pre>` — Code block
- `<a href="...">` — Links

## Examples

```
/teams read Kovacsevics                   # Read recent messages with Kovacsevics
/teams find "Apple Mac"                   # Find chat by topic
/teams send Molnár Dávid Hello, could you check the latest PR?
/teams send-to molnar.david@netlock.hu <b>Update:</b> PR is ready for review
/teams list                               # List all recent chats
```
