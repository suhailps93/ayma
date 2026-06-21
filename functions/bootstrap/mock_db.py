import sqlite3
import re
import asyncio
from pathlib import Path

class MockConnection:
    def __init__(self, db_path: str):
        self.db_path = db_path
        self.conn = None

    async def __aenter__(self):
        self.conn = await asyncio.to_thread(sqlite3.connect, self.db_path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.conn:
            await asyncio.to_thread(self.conn.commit)
            await asyncio.to_thread(self.conn.close)

    def _translate(self, query: str, args: tuple) -> tuple[str, tuple]:
        """Translate PostgreSQL parameterized query to SQLite.
        Handles: repeated $N refs, ANY($N) arrays, ::cast, NOW(), ILIKE, ::vector, <=> (pgvector).
        PostgreSQL $1 may appear multiple times (same binding each time).
        SQLite ? is positional — one value per occurrence.
        """
        args_list = list(args)
        out_args: list = []

        # Pass 1: Strip pgvector <=> ORDER BY terms BEFORE $N substitution.
        # These consume a parameter that SQLite cannot use (no vector math).
        # Track which 1-based PG parameter indices are consumed by <=> so we skip them in Pass 2.
        vector_consumed: set[int] = set()

        def _strip_vector(m):
            pg_idx = int(m.group(1))  # 1-based (only one capture group in the <=> pattern)
            vector_consumed.add(pg_idx)
            return "(SELECT 0)"  # safe constant expression for ORDER BY in SQLite

        query = re.sub(
            r'\w+\s*<=>\s*\$(\d+)(?:::\s*vector)?',
            _strip_vector,
            query,
            flags=re.IGNORECASE,
        )
        # Remove dangling ", (SELECT 0) ASC/DESC" fragments left in ORDER BY
        query = re.sub(r',\s*\(SELECT 0\)\s*(?:ASC|DESC)?', '', query, flags=re.IGNORECASE)

        # Pass 2: Substitute $N and = ANY($N), skipping vector-consumed params.
        pattern = re.compile(r'= ANY\(\$(\d+)\)|\$(\d+)')

        def replacer(m):
            if m.group(1) is not None:
                # = ANY($N) → IN (?,?,...)
                pg_idx = int(m.group(1))
                if pg_idx in vector_consumed:
                    return "IN (NULL)"
                idx = pg_idx - 1
                val = args_list[idx] if idx < len(args_list) else []
                if isinstance(val, (list, tuple)):
                    out_args.extend(val)
                    return f"IN ({','.join('?' * len(val))})"
                out_args.append(val)
                return "IN (?)"
            else:
                # $N → ? (possibly repeated — each occurrence gets the same value)
                pg_idx = int(m.group(2))
                if pg_idx in vector_consumed:
                    return "(SELECT 0)"  # emit no binding
                idx = pg_idx - 1
                val = args_list[idx] if idx < len(args_list) else None
                out_args.append(val)
                return "?"

        query = pattern.sub(replacer, query)
        query = re.sub(r'::\s*vector', '', query)
        query = query.replace("::jsonb", "").replace("::json", "")
        query = query.replace("NOW()", "CURRENT_TIMESTAMP")
        query = query.replace("ILIKE", "LIKE")
        return query, tuple(out_args)

    async def fetch(self, query: str, *args):
        translated, args = self._translate(query, args)
        def _run():
            cursor = self.conn.cursor()
            cursor.execute(translated, args)
            return cursor.fetchall()
        return await asyncio.to_thread(_run)

    async def fetchrow(self, query: str, *args):
        translated, args = self._translate(query, args)
        def _run():
            cursor = self.conn.cursor()
            cursor.execute(translated, args)
            return cursor.fetchone()
        return await asyncio.to_thread(_run)

    async def fetchval(self, query: str, *args):
        translated, args = self._translate(query, args)
        def _run():
            cursor = self.conn.cursor()
            cursor.execute(translated, args)
            row = cursor.fetchone()
            if row:
                return row[0]
            return None
        return await asyncio.to_thread(_run)

    async def execute(self, query: str, *args):
        translated, args = self._translate(query, args)
        def _run():
            cursor = self.conn.cursor()
            cursor.execute(translated, args)
            self.conn.commit()
            return f"UPDATE {cursor.rowcount}"
        return await asyncio.to_thread(_run)

    async def executemany(self, query: str, args_list):
        translated, _ = self._translate(query, ())
        def _run():
            cursor = self.conn.cursor()
            cursor.executemany(translated, args_list)
            self.conn.commit()
            return f"UPDATE {cursor.rowcount}"
        return await asyncio.to_thread(_run)

class MockPool:
    def __init__(self, db_path: str = "ayma.db"):
        self.db_path = str(Path(__file__).parent.resolve() / db_path)

    def acquire(self):
        return MockConnection(self.db_path)

    async def close(self):
        pass

    async def init_db(self):
        async with self.acquire() as conn:
            def _create():
                c = conn.conn.cursor()
                c.execute("""
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY,
                    display_name TEXT,
                    profile_public TEXT DEFAULT '',
                    profile_private TEXT DEFAULT '',
                    profile_ai_observations TEXT DEFAULT '',
                    agent_name TEXT DEFAULT 'Ayma',
                    voice_preference TEXT DEFAULT 'Charon',
                    matching_prefs TEXT DEFAULT '{}',
                    age INTEGER,
                    gender TEXT,
                    location_region TEXT,
                    location_coords TEXT DEFAULT '{}',
                    onboarding_complete BOOLEAN DEFAULT 0,
                    matching_paused BOOLEAN DEFAULT 0,
                    preboarding_seen BOOLEAN DEFAULT 0,
                    photo_order TEXT DEFAULT '[]',
                    voice_settings TEXT DEFAULT '{}',
                    profile_public_locked BOOLEAN DEFAULT 0,
                    community_profile TEXT DEFAULT 'dating_standard',
                    profile_public_user_edited BOOLEAN DEFAULT 0,
                    profile_public_pending TEXT DEFAULT '',
                    wiki_about_me TEXT DEFAULT '',
                    wiki_context TEXT DEFAULT '',
                    wiki_preferences TEXT DEFAULT '',
                    wiki_matching TEXT DEFAULT '',
                    wiki_profile_structured TEXT DEFAULT '',
                    profile_answers TEXT DEFAULT '{}',
                    profile_answers_public TEXT DEFAULT '{}',
                    profile_answers_private TEXT DEFAULT '{}',
                    profile_answers_sensitive TEXT DEFAULT '{}',
                    profile_field_visibility TEXT DEFAULT '{}',
                    raw_user_statements TEXT DEFAULT '[]',
                    matching_embedding TEXT,
                    fcm_token TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS user_skills (
                    user_id TEXT,
                    skill_id TEXT,
                    name TEXT,
                    content TEXT,
                    enabled BOOLEAN DEFAULT 1,
                    PRIMARY KEY (user_id, skill_id)
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS user_questions (
                    user_id TEXT,
                    question_id TEXT,
                    key TEXT,
                    text TEXT,
                    category TEXT,
                    sort_order INTEGER DEFAULT 99,
                    answered BOOLEAN DEFAULT 0,
                    answered_at TEXT,
                    is_followup BOOLEAN DEFAULT 0,
                    PRIMARY KEY (user_id, question_id)
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS matches (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_a TEXT,
                    user_b TEXT,
                    score REAL,
                    rationale TEXT,
                    summary_a TEXT,
                    summary_b TEXT,
                    synergy_score INTEGER,
                    synergy_summary TEXT,
                    status TEXT DEFAULT 'pending',
                    show_simulation_transcript BOOLEAN DEFAULT 1,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(user_a, user_b)
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS match_simulations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    match_id INTEGER,
                    sender_uid TEXT,
                    turn_index INTEGER NOT NULL,
                    message_text TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS user_memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT,
                    text TEXT NOT NULL,
                    session_id TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS user_media (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT,
                    photo_url TEXT NOT NULL,
                    caption TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS notifications (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id TEXT,
                    type TEXT,
                    title TEXT,
                    body TEXT,
                    meta TEXT DEFAULT '{}',
                    read BOOLEAN DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                """)
                c.execute("""
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    from_user_id TEXT,
                    to_user_id TEXT,
                    text TEXT NOT NULL,
                    read BOOLEAN DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                );
                """)
                conn.conn.commit()
            await asyncio.to_thread(_create)
