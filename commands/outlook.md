---
description: Read, search, and send Outlook emails as Gergő
---

# Outlook Email

Read inbox, search emails, read full messages, send/reply/forward emails, and manage drafts via the n8n + MS Graph API integration. All actions are performed as kiss.gergo@netlock.hu.

## Usage

```
/outlook inbox [count]                    List recent inbox emails
/outlook read <message_id>                Read a full email
/outlook search <query>                   Full-text search across all emails
/outlook from <email>                     Find emails from a specific sender
/outlook subject <keyword>                Search emails by subject
/outlook send <email> <subject> <body>    Send an email
/outlook reply <message_id> <body>        Reply to an email
/outlook forward <message_id> <email>     Forward an email
/outlook draft <email> <subject> <body>   Create a draft (does not send)
/outlook attachments <message_id>         List attachments on an email
/outlook folders                          List all mail folders
```

If `$ARGUMENTS` is empty, show the user's inbox (last 10 emails).

## Process

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the action:

- First word = command (`inbox`, `read`, `search`, `from`, `subject`, `send`, `reply`, `forward`, `draft`, `attachments`, `folders`)
- If no recognized command, treat the whole argument as a `search` query
- If the user says something like "check my email" or "what's new", run `inbox`
- If the user says "email from X", run `from`
- If the user pastes a message ID (long alphanumeric string), run `read`

### Step 2: Execute Action

#### `inbox [count]` — List Recent Emails
```bash
~/.claude/scripts/outlook-api.sh inbox 15
```
Display as a clean list:
```
1. [UNREAD] Subject Line Here
   From: Name <email@domain.com> | 2026-03-20 14:35 | 📎
2. Subject Line Here
   From: Name <email@domain.com> | 2026-03-19 09:12
```
- Mark unread emails with `[UNREAD]`
- Show 📎 if `hasAttachments` is true
- Show ⚡ if `importance` is "high"

#### `read <message_id>` — Read Full Email
```bash
~/.claude/scripts/outlook-api.sh read "<message_id>"
```
Display the full email:
```
Subject: ...
From: Name <email>
To: recipient1, recipient2
CC: cc1, cc2
Date: 2026-03-20 14:35
Attachments: file1.pdf (120KB), file2.xlsx (45KB)
---
Body content here...
```

#### `search <query>` — Full-Text Search
```bash
~/.claude/scripts/outlook-api.sh search "<query>" 10
```
The query supports Microsoft Graph search syntax. Display results like inbox.

#### `from <email>` — Search by Sender
```bash
~/.claude/scripts/outlook-api.sh search-from "<email>" 10
```
If the user gives a name instead of email, try to resolve it:
- Check known contacts table below
- Or use a partial email search

#### `subject <keyword>` — Search by Subject
```bash
~/.claude/scripts/outlook-api.sh search-subject "<keyword>" 10
```

#### `send <email> <subject> <body>` — Send Email
1. Format the body as HTML:
   - Convert markdown to HTML (`**bold**` → `<b>bold</b>`, etc.)
   - Preserve line breaks as `<br>`
2. **ALWAYS append signature:**
   ```html
   <br><br>--<br>
   Kiss Gergő<br>
   Technical Product Manager<br>
   NETLOCK Kft.<br>
   <i>🤖 Sent by Gergő's AI Assistant</i>
   ```
3. **Show the user the formatted email before sending** and ask for confirmation
4. Send:
```bash
~/.claude/scripts/outlook-api.sh send "<email>" "<subject>" "<html_body>"
```

#### `reply <message_id> <body>` — Reply to Email
1. First **read the original email** so you understand context:
```bash
~/.claude/scripts/outlook-api.sh read "<message_id>"
```
2. Format the reply body as HTML with signature
3. **Show the user the reply before sending** and ask for confirmation
4. Reply:
```bash
~/.claude/scripts/outlook-api.sh reply "<message_id>" "<html_body>"
```

#### `forward <message_id> <email> [comment]` — Forward Email
1. First **read the original email** to show what will be forwarded
2. **Confirm with user** before forwarding
3. Forward:
```bash
~/.claude/scripts/outlook-api.sh forward "<message_id>" "<email>" "<optional_comment>"
```

#### `draft <email> <subject> <body>` — Create Draft
Same as `send` but creates a draft instead. No confirmation needed (it's just a draft).
```bash
~/.claude/scripts/outlook-api.sh draft "<email>" "<subject>" "<html_body>"
```
Report the draft ID so the user can find it.

#### `attachments <message_id>` — List Attachments
```bash
~/.claude/scripts/outlook-api.sh attachments "<message_id>"
```
Display attachment list with name, size, and content type.

#### `folders` — List Mail Folders
```bash
~/.claude/scripts/outlook-api.sh folders
```
Display folders with unread counts.

### Step 3: Display Results

Format all output for readability:
- Clean up HTML entities
- Strip HTML tags from email bodies
- Format dates in a readable way
- For long emails, summarize if the user asks
- Show message IDs so the user can reference them for reply/forward

## Important Guidelines

1. **Always confirm before sending** — Show the formatted email and ask "Send this?" before actually sending. NEVER send without confirmation unless the user explicitly said to skip.
2. **Include signature on all outgoing emails** — Every sent/replied email must have the signature block.
3. **Read before reply** — Always read the original email before composing a reply so you have context.
4. **Message IDs are opaque strings** — They're long base64-like strings from Graph API. Always pass them exactly as received.
5. **HTML content** — All email bodies use HTML contentType. Convert markdown formatting when composing.
6. **Rate limiting** — Each operation creates/destroys an n8n workflow. Don't run more than ~5 operations quickly.
7. **Sensitive content** — Emails may contain confidential information. Don't log email bodies to external systems.
8. **Error handling** — If n8n returns an error, report it clearly and suggest checking if the n8n instance or OAuth token is working.

## Email Signature

Always append this to outgoing emails:

```html
<br><br>--<br>
Kiss Gergő<br>
Technical Product Manager<br>
NETLOCK Kft.<br>
<i>🤖 Sent by Gergő's AI Assistant</i>
```

## Common Workflows

**Check what's new:**
```
/outlook inbox
```

**Find and read a specific email:**
```
/outlook from somkuti.andras@netlock.com
/outlook read <message_id_from_above>
```

**Reply to an email:**
```
/outlook reply <message_id> "Thanks for the update, I'll review the PR today."
```

**Send a new email:**
```
/outlook send molnar.david@netlock.hu "Sprint Review Notes" "Hi Dávid,<br><br>Here are the notes from today's review..."
```

**Search for something specific:**
```
/outlook search "Trulioo contract"
/outlook subject "deploy"
```

## Examples

```
/outlook inbox 5                              # Last 5 emails
/outlook search "GitHub Actions"              # Full-text search
/outlook from penk.richard@netlock.hu         # Emails from Richárd
/outlook read AAMkAD...                       # Read specific email
/outlook reply AAMkAD... "Looks good, approved!"
/outlook send someone@netlock.hu "Meeting" "Can we meet at 3pm?"
/outlook draft someone@netlock.hu "Proposal" "Draft proposal content..."
/outlook folders                              # Show all folders
/outlook attachments AAMkAD...                # List attachments
```
