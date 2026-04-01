#!/usr/bin/env python3
"""
Teams Intelligence Layer — Core Database Module

SQLite + sqlite-vec + FTS5 storage for Teams messages.
Used by all other teams-intel scripts.

Usage:
    python3 db.py init          Create/upgrade database schema
    python3 db.py test          Insert test data and verify all features
    python3 db.py stats         Show database statistics
    python3 db.py search <q>    Quick keyword search (FTS5)
"""

import json
import os
import sqlite3
import struct
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import sqlite_vec

# Paths
DB_DIR = Path(os.environ.get("TEAMS_INTEL_DIR", Path.home() / ".claude" / "teams-intel"))
DB_PATH = DB_DIR / "teams.db"
CONFIG_PATH = DB_DIR / "config.json"

# Embedding dimensions (from config or default)
EMBED_DIM = 1024


def get_config() -> dict:
    """Load config.json or return defaults."""
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            return json.load(f)
    return {
        "embedding_model": "qwen3-embedding:0.6b",
        "embedding_dimensions": EMBED_DIM,
        "summary_model": "qwen3:14b",
        "ollama_url": "http://localhost:11434",
        "poll_interval": 300,
        "summary_interval_business": 3600,
        "summary_interval_other": 14400,
        "business_hours": {"start": 8, "end": 19, "timezone": "Europe/Budapest"},
        "business_days": [0, 1, 2, 3, 4],
        "message_retention_days": 90,
        "self_user_id": "873ef3a0-041c-458f-8af5-c44e6db0dcaf",
        "chat_tags": {},
        "chat_blacklist": [],
        "github_repos": [
            "netlock-solutions/ncs-backend",
            "netlock-solutions/ncs-frontend",
            "netlock-solutions/ayacucho-certificate-liveness-ms",
            "netlock-solutions/aws-n8n",
        ],
    }


def get_db(readonly: bool = False) -> sqlite3.Connection:
    """Open database connection with sqlite-vec loaded."""
    if readonly:
        uri = f"file:{DB_PATH}?mode=ro"
        db = sqlite3.connect(uri, uri=True)
    else:
        db = sqlite3.connect(str(DB_PATH))
    db.enable_load_extension(True)
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA foreign_keys=ON")
    db.row_factory = sqlite3.Row
    return db


SCHEMA_SQL = """
-- Chat metadata
CREATE TABLE IF NOT EXISTS chats (
    id TEXT PRIMARY KEY,
    topic TEXT,
    chat_type TEXT,        -- 'oneOnOne', 'group', 'meeting'
    members TEXT,          -- JSON array of {id, name, email}
    tags TEXT DEFAULT '',  -- comma-separated: 'work', 'social', 'work:status-dev'
    first_seen TEXT,
    last_seen TEXT,
    message_count INTEGER DEFAULT 0
);

-- Raw messages
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL REFERENCES chats(id),
    sender_name TEXT,
    sender_id TEXT,
    body TEXT,              -- plain text (HTML stripped)
    body_html TEXT,         -- original HTML
    timestamp TEXT NOT NULL,
    has_attachments INTEGER DEFAULT 0,
    github_refs TEXT,       -- JSON array of refs found in body
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_messages_chat_time ON messages(chat_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_name);

-- FTS5 full-text search on message bodies
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    body,
    sender_name,
    content=messages,
    content_rowid=rowid,
    tokenize='unicode61 remove_diacritics 2'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, body, sender_name)
    VALUES (new.rowid, new.body, new.sender_name);
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, body, sender_name)
    VALUES ('delete', old.rowid, old.body, old.sender_name);
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, body, sender_name)
    VALUES ('delete', old.rowid, old.body, old.sender_name);
    INSERT INTO messages_fts(rowid, body, sender_name)
    VALUES (new.rowid, new.body, new.sender_name);
END;

-- Summaries (per-chat hourly/daily)
CREATE TABLE IF NOT EXISTS summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id TEXT REFERENCES chats(id),
    period_start TEXT NOT NULL,
    period_end TEXT NOT NULL,
    summary TEXT,
    message_count INTEGER DEFAULT 0,
    participants TEXT,      -- JSON array of names
    key_topics TEXT,        -- JSON array
    action_items TEXT,      -- JSON array
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_summaries_chat_period ON summaries(chat_id, period_start);

-- GitHub cross-references
CREATE TABLE IF NOT EXISTS github_refs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id TEXT REFERENCES messages(id),
    ref_type TEXT,          -- 'issue' or 'pull'
    ref_number INTEGER,
    repo TEXT,
    title TEXT,
    state TEXT,
    url TEXT,
    fetched_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_github_refs_msg ON github_refs(message_id);
CREATE INDEX IF NOT EXISTS idx_github_refs_num ON github_refs(ref_number, repo);

-- Digest log (aggregated cross-chat summaries)
CREATE TABLE IF NOT EXISTS digest_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    period_start TEXT NOT NULL,
    period_end TEXT NOT NULL,
    digest TEXT,
    chat_count INTEGER DEFAULT 0,
    message_count INTEGER DEFAULT 0,
    sent_telegram INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Key-value config store
CREATE TABLE IF NOT EXISTS config (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""

# sqlite-vec table (created separately because virtual tables use different syntax)
VEC_TABLE_SQL = """
CREATE VIRTUAL TABLE IF NOT EXISTS embeddings_vec USING vec0(
    message_id TEXT PRIMARY KEY,
    embedding float[{dim}]
);
"""


def init_db(db: Optional[sqlite3.Connection] = None) -> sqlite3.Connection:
    """Create all tables and indexes."""
    close = db is None
    if db is None:
        db = get_db()

    db.executescript(SCHEMA_SQL)

    config = get_config()
    dim = config.get("embedding_dimensions", EMBED_DIM)
    db.execute(VEC_TABLE_SQL.format(dim=dim))

    # Set initial config values if not present
    defaults = {
        "last_ingestion_time": "",
        "last_summary_time": "",
        "schema_version": "1",
    }
    for key, value in defaults.items():
        db.execute(
            "INSERT OR IGNORE INTO config(key, value) VALUES (?, ?)",
            (key, value),
        )

    db.commit()
    if close:
        db.close()
    return db


def get_config_value(db: sqlite3.Connection, key: str) -> Optional[str]:
    """Get a config value from the DB."""
    row = db.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def set_config_value(db: sqlite3.Connection, key: str, value: str):
    """Set a config value in the DB."""
    db.execute(
        "INSERT OR REPLACE INTO config(key, value) VALUES (?, ?)",
        (key, value),
    )
    db.commit()


def upsert_chat(db: sqlite3.Connection, chat_id: str, topic: str = "",
                chat_type: str = "", members: list = None):
    """Insert or update a chat record."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    members_json = json.dumps(members or [])

    # Get tags from config
    config = get_config()
    tags = config.get("chat_tags", {}).get(chat_id, "")

    existing = db.execute("SELECT id FROM chats WHERE id = ?", (chat_id,)).fetchone()
    if existing:
        db.execute("""
            UPDATE chats SET topic = COALESCE(NULLIF(?, ''), topic),
                             chat_type = COALESCE(NULLIF(?, ''), chat_type),
                             members = CASE WHEN ? != '[]' THEN ? ELSE members END,
                             tags = COALESCE(NULLIF(?, ''), tags),
                             last_seen = ?
            WHERE id = ?
        """, (topic, chat_type, members_json, members_json, tags, now, chat_id))
    else:
        db.execute("""
            INSERT INTO chats(id, topic, chat_type, members, tags, first_seen, last_seen, message_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0)
        """, (chat_id, topic, chat_type, members_json, tags, now, now))
    db.commit()


def insert_message(db: sqlite3.Connection, msg_id: str, chat_id: str,
                   sender_name: str, sender_id: str, body: str,
                   body_html: str, timestamp: str,
                   has_attachments: bool = False,
                   github_refs: list = None) -> bool:
    """Insert a message. Returns True if inserted (not duplicate)."""
    existing = db.execute("SELECT id FROM messages WHERE id = ?", (msg_id,)).fetchone()
    if existing:
        return False

    db.execute("""
        INSERT INTO messages(id, chat_id, sender_name, sender_id, body, body_html,
                             timestamp, has_attachments, github_refs)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (msg_id, chat_id, sender_name, sender_id, body, body_html,
          timestamp, int(has_attachments), json.dumps(github_refs or [])))

    # Update chat message count and last_seen
    db.execute("""
        UPDATE chats SET message_count = message_count + 1,
                         last_seen = MAX(COALESCE(last_seen, ''), ?)
        WHERE id = ?
    """, (timestamp, chat_id))

    db.commit()
    return True


def serialize_float32(vec: list[float]) -> bytes:
    """Serialize a list of floats to bytes for sqlite-vec."""
    return struct.pack(f"{len(vec)}f", *vec)


def insert_embedding(db: sqlite3.Connection, message_id: str, embedding: list[float]):
    """Store an embedding vector for a message."""
    vec_bytes = serialize_float32(embedding)
    db.execute(
        "INSERT OR REPLACE INTO embeddings_vec(message_id, embedding) VALUES (?, ?)",
        (message_id, vec_bytes),
    )
    db.commit()


def search_fts(db: sqlite3.Connection, query: str, limit: int = 20) -> list[dict]:
    """Full-text keyword search using FTS5 BM25 ranking."""
    rows = db.execute("""
        SELECT m.id, m.chat_id, m.sender_name, m.body, m.timestamp,
               c.topic as chat_topic, bm25(messages_fts) as score
        FROM messages_fts f
        JOIN messages m ON m.rowid = f.rowid
        LEFT JOIN chats c ON c.id = m.chat_id
        WHERE messages_fts MATCH ?
        ORDER BY bm25(messages_fts)
        LIMIT ?
    """, (query, limit)).fetchall()
    return [dict(r) for r in rows]


def search_vector(db: sqlite3.Connection, query_embedding: list[float],
                  limit: int = 20) -> list[dict]:
    """Semantic search using sqlite-vec cosine similarity."""
    vec_bytes = serialize_float32(query_embedding)
    rows = db.execute("""
        SELECT v.message_id as id, v.distance as score,
               m.chat_id, m.sender_name, m.body, m.timestamp,
               c.topic as chat_topic
        FROM embeddings_vec v
        JOIN messages m ON m.id = v.message_id
        LEFT JOIN chats c ON c.id = m.chat_id
        WHERE v.embedding MATCH ?
          AND k = ?
        ORDER BY v.distance
    """, (vec_bytes, limit)).fetchall()
    return [dict(r) for r in rows]


def get_messages_since(db: sqlite3.Connection, chat_id: str,
                       since: str, limit: int = 100) -> list[dict]:
    """Get messages from a chat since a given timestamp."""
    rows = db.execute("""
        SELECT m.*, c.topic as chat_topic
        FROM messages m
        LEFT JOIN chats c ON c.id = m.chat_id
        WHERE m.chat_id = ? AND m.timestamp > ?
        ORDER BY m.timestamp ASC
        LIMIT ?
    """, (chat_id, since, limit)).fetchall()
    return [dict(r) for r in rows]


def get_recent_messages(db: sqlite3.Connection, hours: int = 1,
                        limit: int = 200) -> list[dict]:
    """Get all recent messages across all chats."""
    rows = db.execute("""
        SELECT m.*, c.topic as chat_topic
        FROM messages m
        LEFT JOIN chats c ON c.id = m.chat_id
        WHERE m.timestamp > datetime('now', ? || ' hours')
        ORDER BY m.timestamp DESC
        LIMIT ?
    """, (f"-{hours}", limit)).fetchall()
    return [dict(r) for r in rows]


def get_stats(db: sqlite3.Connection) -> dict:
    """Get database statistics."""
    stats = {}
    stats["messages"] = db.execute("SELECT COUNT(*) as n FROM messages").fetchone()["n"]
    stats["chats"] = db.execute("SELECT COUNT(*) as n FROM chats").fetchone()["n"]
    stats["summaries"] = db.execute("SELECT COUNT(*) as n FROM summaries").fetchone()["n"]
    stats["github_refs"] = db.execute("SELECT COUNT(*) as n FROM github_refs").fetchone()["n"]
    stats["digests"] = db.execute("SELECT COUNT(*) as n FROM digest_log").fetchone()["n"]

    # Embedding count
    try:
        stats["embeddings"] = db.execute(
            "SELECT COUNT(*) as n FROM embeddings_vec"
        ).fetchone()["n"]
    except Exception:
        stats["embeddings"] = 0

    # DB file size
    if DB_PATH.exists():
        stats["db_size_mb"] = round(DB_PATH.stat().st_size / 1024 / 1024, 2)
    else:
        stats["db_size_mb"] = 0

    # Last ingestion
    stats["last_ingestion"] = get_config_value(db, "last_ingestion_time") or "never"
    stats["last_summary"] = get_config_value(db, "last_summary_time") or "never"

    # Oldest/newest message
    oldest = db.execute("SELECT MIN(timestamp) as t FROM messages").fetchone()
    newest = db.execute("SELECT MAX(timestamp) as t FROM messages").fetchone()
    stats["oldest_message"] = oldest["t"] if oldest else None
    stats["newest_message"] = newest["t"] if newest else None

    return stats


# ── CLI ──────────────────────────────────────────────────────────

def cmd_init():
    """Initialize the database."""
    DB_DIR.mkdir(parents=True, exist_ok=True)
    db = init_db()
    db.close()
    print(f"Database initialized at {DB_PATH}")

    # Create config.json if it doesn't exist
    if not CONFIG_PATH.exists():
        config = get_config()
        with open(CONFIG_PATH, "w") as f:
            json.dump(config, f, indent=2)
        print(f"Config created at {CONFIG_PATH}")


def cmd_test():
    """Insert test data and verify all features work."""
    DB_DIR.mkdir(parents=True, exist_ok=True)
    db = get_db()
    init_db(db)

    print("=== Teams Intel DB Test ===\n")

    # 1. Insert test chat
    print("1. Inserting test chat...")
    upsert_chat(db, "test-chat-001", topic="Test Channel", chat_type="group",
                members=[{"id": "u1", "name": "Test User", "email": "test@netlock.hu"}])
    chat = db.execute("SELECT * FROM chats WHERE id = 'test-chat-001'").fetchone()
    assert chat is not None, "Chat insert failed"
    print(f"   OK: chat '{chat['topic']}' created")

    # 2. Insert test messages
    print("2. Inserting test messages...")
    test_msgs = [
        ("msg-001", "test-chat-001", "Molnár Dávid", "u1",
         "The staging deploy failed because of a missing migration",
         "<p>The staging deploy failed because of a missing migration</p>",
         "2026-03-25T14:30:00Z"),
        ("msg-002", "test-chat-001", "Kovacsevics András", "u2",
         "I fixed issue #121 in the ncs-backend repo yesterday",
         "<p>I fixed issue #121 in the ncs-backend repo yesterday</p>",
         "2026-03-25T14:35:00Z"),
        ("msg-003", "test-chat-001", "Penk Richárd", "u3",
         "The auth module tests are failing, checking now",
         "<p>The auth module tests are failing, checking now</p>",
         "2026-03-25T14:40:00Z"),
    ]
    for args in test_msgs:
        inserted = insert_message(db, *args)
        print(f"   {'Inserted' if inserted else 'Skipped (dup)'}: {args[0]}")

    # Verify no duplicates
    dup = insert_message(db, *test_msgs[0])
    assert not dup, "Duplicate prevention failed"
    print("   OK: duplicate prevention works")

    # 3. FTS5 search
    print("3. Testing FTS5 search...")
    results = search_fts(db, "deploy migration")
    assert len(results) > 0, "FTS5 search returned no results"
    print(f"   OK: FTS5 found {len(results)} result(s) for 'deploy migration'")
    print(f"   Top result: [{results[0]['sender_name']}] {results[0]['body'][:60]}...")

    results2 = search_fts(db, "auth tests")
    assert len(results2) > 0, "FTS5 search for 'auth tests' failed"
    print(f"   OK: FTS5 found {len(results2)} result(s) for 'auth tests'")

    # 4. Vector embedding (mock — Ollama may be offline)
    print("4. Testing vector storage...")
    import random
    config = get_config()
    dim = config.get("embedding_dimensions", EMBED_DIM)
    for msg_id in ["msg-001", "msg-002", "msg-003"]:
        mock_embedding = [random.gauss(0, 1) for _ in range(dim)]
        insert_embedding(db, msg_id, mock_embedding)
    print(f"   OK: stored {dim}-dim embeddings for 3 messages")

    # 5. Vector search
    print("5. Testing vector search...")
    query_vec = [random.gauss(0, 1) for _ in range(dim)]
    results = search_vector(db, query_vec, limit=3)
    assert len(results) > 0, "Vector search returned no results"
    print(f"   OK: vector search returned {len(results)} result(s)")
    print(f"   Distances: {[round(r['score'], 4) for r in results]}")

    # 6. Messages since
    print("6. Testing temporal queries...")
    recent = get_messages_since(db, "test-chat-001", "2026-03-25T14:32:00Z")
    assert len(recent) == 2, f"Expected 2 messages after 14:32, got {len(recent)}"
    print(f"   OK: found {len(recent)} messages after 14:32")

    # 7. Stats
    print("7. Checking stats...")
    stats = get_stats(db)
    print(f"   Messages: {stats['messages']}")
    print(f"   Chats: {stats['chats']}")
    print(f"   Embeddings: {stats['embeddings']}")
    print(f"   DB size: {stats['db_size_mb']} MB")

    # 8. Cleanup test data
    print("\n8. Cleaning up test data...")
    db.execute("DELETE FROM embeddings_vec WHERE message_id LIKE 'msg-%'")
    db.execute("DELETE FROM messages WHERE id LIKE 'msg-%'")
    db.execute("DELETE FROM chats WHERE id = 'test-chat-001'")
    db.commit()
    remaining = db.execute("SELECT COUNT(*) as n FROM messages WHERE id LIKE 'msg-%'").fetchone()["n"]
    assert remaining == 0, "Cleanup failed"
    print("   OK: test data cleaned up")

    db.close()
    print("\n=== All tests passed ===")


def cmd_stats():
    """Print database statistics."""
    if not DB_PATH.exists():
        print("Database not found. Run: python3 db.py init")
        sys.exit(1)
    db = get_db(readonly=True)
    stats = get_stats(db)
    db.close()
    print(json.dumps(stats, indent=2))


def cmd_search(query: str):
    """Quick FTS5 search."""
    if not DB_PATH.exists():
        print("Database not found. Run: python3 db.py init")
        sys.exit(1)
    db = get_db(readonly=True)
    results = search_fts(db, query)
    db.close()
    for r in results:
        print(f"[{r['timestamp']}] [{r['chat_topic'] or r['chat_id'][:15]}] "
              f"{r['sender_name']}: {r['body'][:100]}")
    if not results:
        print("No results found.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "init":
        cmd_init()
    elif cmd == "test":
        cmd_test()
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "search" and len(sys.argv) > 2:
        cmd_search(" ".join(sys.argv[2:]))
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)
