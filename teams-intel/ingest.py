#!/usr/bin/env python3
"""
Teams Intelligence Layer — Ingestion Module

Pulls messages from Teams via teams-api.sh and stores in SQLite.
Two-tier polling:
  Tier 1: list-chats (1 API call) → detect which chats have new messages
  Tier 2: read-chat per changed chat → fetch and store new messages

Usage:
    python3 ingest.py              Run one ingestion cycle
    python3 ingest.py --backfill   Backfill: fetch all chats, 50 messages each
    python3 ingest.py --status     Show ingestion status
"""

import html
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Import our DB module
sys.path.insert(0, str(Path(__file__).parent))
import db as tdb

TEAMS_API = Path.home() / ".claude" / "scripts" / "teams-api.sh"


def run_teams_api(*args) -> dict | list | None:
    """Call teams-api.sh and return parsed JSON output."""
    cmd = [str(TEAMS_API)] + list(args)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120
        )
        if result.returncode != 0:
            print(f"  [ERROR] teams-api.sh {' '.join(args)}: {result.stderr.strip()}", file=sys.stderr)
            return None
        output = result.stdout.strip()
        if not output:
            return None
        return json.loads(output)
    except subprocess.TimeoutExpired:
        print(f"  [ERROR] teams-api.sh {' '.join(args)}: timeout", file=sys.stderr)
        return None
    except json.JSONDecodeError as e:
        print(f"  [ERROR] JSON parse failed for {' '.join(args)}: {e}", file=sys.stderr)
        return None


def strip_html(html_str: str) -> str:
    """Strip HTML tags and decode entities."""
    if not html_str:
        return ""
    text = re.sub(r"<[^>]+>", "", html_str)
    text = html.unescape(text).strip()
    text = re.sub(r"\s+", " ", text)
    return text


def detect_github_refs(body: str) -> list[dict]:
    """Find GitHub issue/PR references in message text."""
    refs = []
    # Pattern: #NNN (2-5 digits)
    for m in re.finditer(r"#(\d{2,5})\b", body):
        refs.append({"type": "issue", "number": int(m.group(1)), "repo": ""})

    # Pattern: github.com/owner/repo/(issues|pull)/NNN
    for m in re.finditer(
        r"github\.com/([\w-]+/[\w-]+)/(issues|pull)/(\d+)", body
    ):
        refs.append({
            "type": "pull" if m.group(2) == "pull" else "issue",
            "number": int(m.group(3)),
            "repo": m.group(1),
        })
    return refs


def parse_chat_last_message_time(chat: dict) -> str | None:
    """Extract last message timestamp from a chat's lastMessagePreview."""
    preview = chat.get("lastMessagePreview")
    if not preview:
        return None
    return preview.get("createdDateTime")


def tier1_detect_changes(database: tdb.sqlite3.Connection,
                         chat_count: int = 30,
                         force_all: bool = False) -> list[dict]:
    """
    Tier 1: Call list-chats, compare lastMessagePreview timestamps
    against DB's last_seen per chat. Return list of chats with new messages.
    """
    print("  Tier 1: Fetching chat list...")
    raw = run_teams_api("list-chats", str(chat_count))
    if raw is None:
        return []

    # list-chats returns raw Graph API response with 'value' array
    chats = raw.get("value", []) if isinstance(raw, dict) else raw

    config = tdb.get_config()
    blacklist = config.get("chat_blacklist", [])
    self_id = config.get("self_user_id", "")

    changed = []
    for chat in chats:
        chat_id = chat.get("id", "")
        if not chat_id or chat_id in blacklist:
            continue

        # Get the last message time from the preview
        last_msg_time = parse_chat_last_message_time(chat)
        if not last_msg_time:
            continue

        # Get topic and type
        topic = chat.get("topic") or ""
        chat_type = chat.get("chatType", "")

        # For 1:1 chats without a topic, use member names
        if not topic and chat_type == "oneOnOne":
            members = chat.get("members", [])
            other_names = [
                m.get("displayName", "")
                for m in members
                if m.get("userId", "") != self_id
            ]
            topic = ", ".join(filter(None, other_names)) or "1:1 Chat"

        # Parse members
        members = []
        for m in chat.get("members", []):
            members.append({
                "id": m.get("userId", ""),
                "name": m.get("displayName", ""),
                "email": m.get("email", ""),
            })

        # Check if this chat has newer messages than what we've seen
        if not force_all:
            db_chat = database.execute(
                "SELECT last_seen FROM chats WHERE id = ?", (chat_id,)
            ).fetchone()
            if db_chat is not None and (db_chat["last_seen"] or "") >= last_msg_time:
                continue

        changed.append({
            "id": chat_id,
            "topic": topic,
            "chat_type": chat_type,
            "members": members,
            "last_msg_time": last_msg_time,
        })

    print(f"  Tier 1: {len(changed)} chat(s) with new messages "
          f"(out of {len(chats)} total)")
    return changed


def tier2_fetch_messages(database: tdb.sqlite3.Connection,
                         chat: dict, count: int = 20) -> int:
    """
    Tier 2: Fetch messages from a specific chat and store new ones.
    Returns number of new messages stored.
    """
    chat_id = chat["id"]
    topic = chat.get("topic", "")
    print(f"  Tier 2: Reading '{topic or chat_id[:20]}' ...", end=" ")

    # Ensure chat exists in DB
    tdb.upsert_chat(
        database, chat_id, topic=topic,
        chat_type=chat.get("chat_type", ""),
        members=chat.get("members", []),
    )

    # Fetch messages via teams-api.sh read-chat
    messages = run_teams_api("read-chat", chat_id, str(count))
    if messages is None:
        print("FAILED")
        return 0

    if not isinstance(messages, list):
        print("unexpected format")
        return 0

    config = tdb.get_config()
    self_id = config.get("self_user_id", "")
    new_count = 0

    for msg in messages:
        msg_id = msg.get("id", "")
        if not msg_id:
            continue

        sender = msg.get("from", "system")
        sender_id = ""  # read-chat doesn't return sender ID directly
        timestamp = msg.get("time", "")
        body = msg.get("body", "")
        body_html = msg.get("body_html", body)  # may not have HTML version
        has_att = bool(msg.get("attachments"))

        # Skip system messages
        if msg.get("messageType") and msg["messageType"] != "message":
            continue

        # Detect GitHub refs
        gh_refs = detect_github_refs(body)

        inserted = tdb.insert_message(
            database, msg_id, chat_id,
            sender_name=sender, sender_id=sender_id,
            body=body, body_html=body_html,
            timestamp=timestamp, has_attachments=has_att,
            github_refs=gh_refs,
        )
        if inserted:
            new_count += 1

    print(f"{new_count} new / {len(messages)} fetched")
    return new_count


def run_ingestion_cycle(backfill: bool = False):
    """Run one complete ingestion cycle."""
    start = time.time()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    print(f"[{now}] Starting ingestion cycle" + (" (backfill)" if backfill else ""))

    database = tdb.get_db()
    tdb.init_db(database)

    if backfill:
        # Backfill: fetch all chats with more messages
        chat_count = 50
        msg_count = 50
    else:
        chat_count = 30
        msg_count = 20

    # Tier 1: Detect changes (backfill forces all chats)
    changed_chats = tier1_detect_changes(
        database, chat_count=chat_count, force_all=backfill
    )

    # Tier 2: Fetch messages from changed chats
    total_new = 0
    for chat in changed_chats:
        new = tier2_fetch_messages(database, chat, count=msg_count)
        total_new += new

    # Update last ingestion time
    tdb.set_config_value(database, "last_ingestion_time", now)

    elapsed = round(time.time() - start, 1)
    stats = tdb.get_stats(database)
    database.close()

    print(f"\n  Cycle complete in {elapsed}s: "
          f"{total_new} new messages, "
          f"{stats['messages']} total in DB, "
          f"{stats['chats']} chats tracked")

    return total_new


def show_status():
    """Show ingestion status."""
    if not tdb.DB_PATH.exists():
        print("Database not initialized. Run: python3 db.py init")
        return

    database = tdb.get_db(readonly=True)
    stats = tdb.get_stats(database)
    database.close()

    print(json.dumps(stats, indent=2))


if __name__ == "__main__":
    if "--status" in sys.argv:
        show_status()
    elif "--backfill" in sys.argv:
        run_ingestion_cycle(backfill=True)
    else:
        run_ingestion_cycle()
