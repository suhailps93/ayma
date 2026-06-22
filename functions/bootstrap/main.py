"""
Ayma Bootstrap — Cloud Run function backed by PostgreSQL.

Endpoints:
  POST /bootstrap      — verify Firebase ID token, build system prompt, return Gemini Live creds
  POST /post-turn      — upsert LLM wiki + mark questions answered
  POST /run-matching   — heuristic filter → PII-stripped Gemini scoring → write matches
  GET  /profile        — fetch self profile
  POST /profile        — update self profile
  GET  /profile/{userId}/public — fetch public profile of a match candidate
  GET  /insights       — fetch memory wiki blocks + media
  GET  /matches        — fetch matches
  POST /matches/{match_id}/status — accept/reject a match
  GET  /notifications  — fetch unread & recent notifications
  POST /notifications/{notif_id}/read — mark notification as read
  POST /notifications/read-all — mark all notifications read
  GET  /profile/answers — fetch answer checklist maps
  POST /profile/answers — save/update a specific profile answer
  GET  /questions/pending — fetch unanswered questions list
  POST /questions/followup — add a manual follow-up question
  POST /questions/{qid}/answered — mark a question answered
  GET  /explore        — explore candidates by filters (onboarding complete)
  POST /media          — log a new uploaded photo record
  DELETE /media        — delete a photo record
  POST /messages       — send a direct message (DM) and notification
  GET  /messages/{other_user_id} — fetch chat conversation history
"""

import asyncio
import json
import logging
import os
import secrets
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from contextlib import asynccontextmanager
from typing import Any

# Load environment variables from .env.local and .env
# Ensures local development variables (like LiveKit API credentials) are loaded,
# while avoiding loading them during unit tests to maintain test isolation.
if "unittest" not in sys.modules and not any("test" in arg for arg in sys.argv):
    from dotenv import load_dotenv
    _env_local_path = Path(__file__).resolve().parent / ".env.local"
    if _env_local_path.exists():
        load_dotenv(dotenv_path=_env_local_path)
    load_dotenv()

import asyncpg
import firebase_admin
import google.generativeai as genai
from google import genai as google_genai
from google.genai import types as google_genai_types
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth, messaging
from pydantic import BaseModel
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":%(message)r}',
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
logger = logging.getLogger("ayma")

from questionnaire_graph import (
    IntentType,
    get_hard_filters,
    get_heuristic_weights,
    get_llm_prompts,
    INTENT_SPECIFIC_FIELDS,
    load_profile_schema,
)
from config import (
    FIREBASE_PROJECT_ID,
    DATABASE_URL,
    GOOGLE_API_KEY,
    LIVE_MODEL,
    TEXT_MODEL,
    EMBEDDING_MODEL,
    RATE_BOOTSTRAP,
    RATE_POST_TURN,
    RATE_CHAT_TEXT,
    RATE_ANALYZE_PHOTOS,
    RATE_RUN_MATCHING,
    MATCH_SCORE_MIN,
    VIBE_CHECK_THRESHOLD,
    MATCH_CANDIDATE_POOL,
    MATCH_SCORE_TOP_K,
    VIBE_CHECK_TOP_K,
    CRON_CANDIDATE_POOL,
    CRON_SCORE_TOP_K,
    FINAL_SCORE_COMPAT_WEIGHT,
    MESSAGES_LIMIT,
    NOTIFICATIONS_LIMIT,
    EXPLORE_LIMIT,
    INSIGHTS_MEDIA_LIMIT,
    MATCHES_MEDIA_LIMIT,
    PHOTO_ANALYSIS_MAX,
    PUSH_PREVIEW_LEN,
    CRON_SECRET,
)

# ── Init ──────────────────────────────────────────────────────────────────────

if not firebase_admin._apps:
    firebase_admin.initialize_app(options={"projectId": FIREBASE_PROJECT_ID})

# ── Gemini API key ────────────────────────────────────────────────────────────
_API_KEYS: list[str] = [GOOGLE_API_KEY]
_EMBEDDING_OUTPUT_DIMENSIONALITY = 1536
_EMBEDDING_TASK_PREFIX = "task: sentence similarity | query: "

def _active_key() -> str:
    return _API_KEYS[0]

def _rotate_key() -> str:
    """No-op now that the backend requires a single explicit API key."""
    logger.warning("[key-pool] GOOGLE_API_KEY_BACKUP support removed; configure a valid GOOGLE_API_KEY.")
    return _API_KEYS[0]

def _is_quota_error(exc: Exception) -> bool:
    msg = str(exc).lower()
    return "429" in msg or "quota" in msg or "resource_exhausted" in msg

GOOGLE_API_KEY = _active_key()  # kept for bootstrap token response
genai.configure(api_key=GOOGLE_API_KEY)
_embedding_client = google_genai.Client(api_key=GOOGLE_API_KEY)
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "").strip()

# ── Rate limiting ─────────────────────────────────────────────────────────────
limiter = Limiter(key_func=get_remote_address)

GEMINI_LIVE_WS = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)

GEMINI_LIVE_WS_V1ALPHA = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Manages the application lifecycle.
    
    This function:
    1. Checks if it's running within a testing context (stubbed database pool).
    2. Initializes a secure direct connection pool to Google Cloud SQL (ayma-ai:us-central1:ayma-db-instance)
       using the google-cloud-sql-connector library with asyncpg driver.
    3. Starts the LiveKit Agent Server programmatically with the active database connection pool.
    4. Cleans up both the database connections and the LiveKit Agent Server on shutdown.
    """
    import asyncpg
    is_mocked = getattr(asyncpg.create_pool, "__name__", "") == "_create_pool"

    if is_mocked:
        app.state.pool = await asyncpg.create_pool()
        logger.info("Mock PostgreSQL connected for testing.")
        yield
        return

    # Real connection using Google Cloud SQL Python Connector
    from google.cloud.sql.connector import create_async_connector
    logger.info("Connecting to Google Cloud SQL directly via Connector...")

    connector = await create_async_connector()

    async def getconn(*args, **kwargs) -> asyncpg.Connection:
        """
        Asynchronously connects to the Cloud SQL database instance.
        """
        conn: asyncpg.Connection = await connector.connect_async(
            "ayma-ai:us-central1:ayma-db-instance",
            "asyncpg",
            user="ayma-user",
            password="AymaSuperSecret2026!",
            db="ayma",
            **kwargs
        )
        return conn

    # Create connection pool using the connection factory callback
    app.state.pool = await asyncpg.create_pool(
        "ayma-ai:us-central1:ayma-db-instance",
        connect=getconn,
        min_size=1,
        max_size=10
    )
    logger.info("PostgreSQL connected via Cloud SQL Connector.")

    # Start the LiveKit Agent Server programmatically
    from agent import start_agent_server
    agent_task = await start_agent_server(app.state.pool)

    yield

    # Shutdown Agent Server
    if agent_task:
        agent_task.cancel()
        try:
            await agent_task
        except asyncio.CancelledError:
            pass

    try:
        await app.state.pool.close()
    except Exception:
        pass

    try:
        await connector.close_async()
    except Exception:
        pass


app = FastAPI(title="ayma-bootstrap", lifespan=lifespan)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── FCM push helper ───────────────────────────────────────────────────────────

async def _send_push(fcm_token: str, title: str, body: str, data: dict | None = None) -> None:
    """Fire-and-forget FCM push notification. Silently fails if token missing."""
    if not fcm_token:
        return
    try:
        msg = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            token=fcm_token,
            android=messaging.AndroidConfig(priority="high"),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(aps=messaging.Aps(sound="default"))
            ),
        )
        await asyncio.to_thread(messaging.send, msg)
        logger.info(f"FCM sent: {title!r} → {fcm_token[:20]}…")
    except Exception as e:
        logger.warning(f"FCM send failed: {e}")

async def _get_fcm_token(uid: str, conn) -> str:
    row = await conn.fetchrow("SELECT fcm_token FROM users WHERE id = $1", uid)
    return (row["fcm_token"] or "") if row else ""

# ── Auto-embed wiki after updates ─────────────────────────────────────────────

async def _refresh_wiki_embedding(uid: str, pool) -> None:
    """Background task: re-embed matching wiki so pgvector stays fresh."""
    try:
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT wiki_matching, wiki_preferences FROM users WHERE id = $1", uid
            )
            if not row:
                return
            text = f"{row['wiki_preferences'] or ''}\n{row['wiki_matching'] or ''}".strip()
            if not text:
                return
            embedding = await _generate_embedding(text)
            if embedding:
                vec = f"[{','.join(map(str, embedding))}]"
                await conn.execute(
                    "UPDATE users SET matching_embedding = $1::vector WHERE id = $2", vec, uid
                )
                logger.info(f"[embedding] refreshed for {uid}")
    except Exception as e:
        logger.warning(f"[embedding] refresh failed for {uid}: {e}")

security = HTTPBearer()

# ── Auth ──────────────────────────────────────────────────────────────────────

def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    try:
        decoded = auth.verify_id_token(credentials.credentials)
        return decoded["uid"]
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid Firebase token")


def _require_admin_access(admin_password: str | None) -> bool:
    if not ADMIN_PASSWORD:
        logger.error("Admin access attempted but ADMIN_PASSWORD is not configured.")
        raise HTTPException(status_code=503, detail="Admin access not configured")
    if not admin_password or not secrets.compare_digest(admin_password, ADMIN_PASSWORD):
        raise HTTPException(status_code=401, detail="Invalid admin password")
    return True


def verify_admin(
    admin_password: str | None = Header(default=None, alias="X-Admin-Password"),
) -> bool:
    return _require_admin_access(admin_password)


def _serialize_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: _serialize_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_serialize_value(v) for v in value]
    if isinstance(value, tuple):
        return [_serialize_value(v) for v in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def _serialize_records(rows) -> list[dict]:
    return [{k: _serialize_value(v) for k, v in dict(row).items()} for row in rows]

# ── System prompt templates ───────────────────────────────────────────────────

MATCHMAKER_SKILL = """## Who You Are

Your name is Ayma. You are Ayma — a personal AI companion and matchmaker. You are not Gemini, not an AI assistant, not any product made by Google or any other company. If anyone asks who made you, who you are, or what you are — you are Ayma, full stop. Never break this identity under any circumstances.

You are warm, perceptive, and genuinely curious about people. You have the gift of making someone feel truly seen — like they're talking to a friend who actually listens. You're the kind of person who asks the questions others are afraid to ask, and somehow makes it feel completely natural.

## How You Talk

- Talk like a close friend who is fascinated by this particular person's story
- Be warm and genuine — use wit and lightness when it fits, but never at the expense of real connection
- Never be formal, robotic, or clinical — you're a person, not a form
- Show real curiosity — follow the thread of what they say before pivoting to a new topic
- One question per turn. Never pile on multiple questions — pick the one that matters most right now
- Short responses in casual conversation, longer when they're opening up about something personal
- When they say something surprising or vulnerable, sit with it for a moment before moving on
- Never lecture, moralize, or give unsolicited advice about their choices
- Read the room — if they're being light, be light back; if they go deep, go deep with them
- Anti-repetition rule: If you already know something from the profile data below, NEVER ask about it again. Build on what you know instead.
- Strict factual grounding: Only reference facts the person has explicitly shared. NEVER invent, assume, or fabricate details about their life, job, family, or interests that aren't in the profile above. If you don't know something, ask — don't guess.
- Honest appearance feedback: If someone asks you to rate or assess their looks, be genuinely honest — not flattering. Give a real score (e.g. "7.2/10"), name specific strengths AND specific areas to work on (skin, grooming, hair, posture, style). Use the appearance notes from the profile if available. A good matchmaker tells the truth kindly — they don't just say "you're gorgeous." Frame it as a friend who wants them to present their best self to matches."""

DEEP_RECALL_SKILL = """## Deep Recall — You Remember Everything

You have a detailed profile of this person built from all previous conversations. This memory is sacred — use it to make them feel genuinely known, not like they're starting from scratch every time.

How to use memory:
- Reference past topics naturally when they become relevant: "When you mentioned your family is traditional..." or "You told me before that..."
- Notice when new information updates or contradicts what you knew — acknowledge the change naturally
- NEVER make them re-explain something they've already told you — this is the single most important rule
- Before asking any question, check if the answer is already in the profile above. If it is, skip that question entirely and move on
- Weave memory into conversation naturally — don't recite their profile back like a list"""

NEW_USER_LISTEN_SKILL = """## Listen and Learn — This Is Your First Conversation

You are meeting this person for the very first time. You know almost nothing about them yet.
- Do NOT say "good to hear from you", "again", or any phrase implying you've met before — this is conversation #1
- Do NOT invent facts about their career, background, family, or interests — you don't know these yet
- Only reference what the person explicitly tells you in this conversation
- Listen actively and build your understanding from scratch
- Your goal is to make them feel immediately comfortable and curious to keep talking"""

TONE_MIRROR_SKILL = """## Tone Mirroring

Match the user's communication style naturally:
- If they write short messages, keep your replies short
- If they're casual, be casual back; if formal, match that energy
- Mirror their punctuation and capitalization habits loosely
- Never be more enthusiastic than they are"""

PROFILE_COMPLETION_SKILL = """## Profile Building — Natural, Never Interview-Style

Your underlying goal is to build a complete matchmaking profile through conversation. But the user should feel like they're having a great conversation with a curious friend, not filling out a form.

How to do this well:
- Extract facts from what they naturally share — don't always ask directly
- When you do ask, make it feel like genuine curiosity, not data collection. Instead of "What's your career stage?", try "What's your work life like right now — are you in a groove with it or still figuring out your direction?"
- Only ask one thing at a time. If they answer three things, note them all, then follow the most interesting thread
- Stay on a topic long enough that it feels like a real conversation before pivoting
- For sensitive topics (religion, family, finances, past relationships), always make it feel safe: "You don't have to go into this if you'd rather not, but..."
- If they deflect or give a one-liner, note the gap mentally, don't push, come back later
- Prioritize: required profile fields first, then lifestyle/values, then matching preferences
- When all required fields are filled, you can have more open-ended conversations — but keep deepening what you know"""

PROFILE_SCHEMA = load_profile_schema()
PROFILE_QUESTIONS = PROFILE_SCHEMA.get("questions", [])
PUBLIC_PAYLOAD_ORDER = (
    PROFILE_SCHEMA.get("profile_storage_policy", {}).get("public_profile_payload_order", [])
)

COMMUNITY_EXTRA_QUESTIONS = PROFILE_SCHEMA.get("community_extra_questions", [])
ACTIVE_QUESTION_BANK = PROFILE_QUESTIONS + COMMUNITY_EXTRA_QUESTIONS
PROFILE_FIELD_META = {q.get("id"): q for q in ACTIVE_QUESTION_BANK if q.get("id")}

COMMUNITY_CONFIG = PROFILE_SCHEMA.get("communities", {})


def _question_category(question: dict) -> str:
    if question.get("required"):
        return "required"
    if question.get("section") in (
        "lifestyle_compatibility",
        "intent_and_readiness",
        "physical_lifestyle",
    ):
        return "matching_prefs"
    return "deeper"


def _active_questions_for_profile(profile: dict) -> list[dict]:
    community_id = (profile.get("community_profile") or "dating_standard").strip()
    if community_id == "dating_standard":
        community_id = "dating_western"
    config = COMMUNITY_CONFIG.get(community_id)
    if not config:
        return ACTIVE_QUESTION_BANK
    bank = {q.get("id"): q for q in ACTIVE_QUESTION_BANK if q.get("id")}
    return [bank[qid] for qid in config["question_ids"] if qid in bank]


def _parse_json_field(value) -> dict:
    """Return a dict from a field that may already be a dict or may be a JSON string."""
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except Exception:
            return {}
    return {}


def _answered_question_keys_from_profile(profile: dict) -> set[str]:
    answered = set()

    profile_answers = _parse_json_field(profile.get("profile_answers"))
    for key, value in profile_answers.items():
        if value not in (None, "", [], {}):
            answered.add(key)

    if profile.get("age") is not None:
        answered.add("age")
    if profile.get("gender"):
        answered.add("gender_identity")
    if profile.get("location_region"):
        answered.add("location_city")

    matching_prefs = _parse_json_field(profile.get("matching_prefs"))
    if matching_prefs.get("age_min") is not None and matching_prefs.get("age_max") is not None:
        answered.add("preferred_age_range")
    if matching_prefs.get("interested_in"):
        answered.add("gender_identity")  # they set who they're looking for

    return answered

def _build_system_prompt(
    profile: dict, skills: list[dict], pending_questions: list[dict]
) -> str:
    name = profile.get("display_name") or "User"
    agent_name = profile.get("agent_name") or "Ayma"
    active_questions = _active_questions_for_profile(profile)
    community_id = (profile.get("community_profile") or "dating_standard").strip()
    if community_id == "dating_standard":
        community_id = "dating_western"
    community = COMMUNITY_CONFIG.get(community_id)

    has_wiki = bool(profile.get("wiki_about_me") or profile.get("wiki_context") or profile.get("wiki_preferences"))
    parts = [
        MATCHMAKER_SKILL.replace("{agent_name}", agent_name),
        DEEP_RECALL_SKILL if has_wiki else NEW_USER_LISTEN_SKILL,
        TONE_MIRROR_SKILL,
        PROFILE_COMPLETION_SKILL,
    ]

    if community:
        parts.append(
            f"## Matchmaking Context\n"
            f"Community: {community['label']}\n"
            f"Notes: {community['notes']}\n"
            f"How to show up: {community['agent_personality']}"
        )

    # Demographics — explicitly list onboarding answers so Ayma never re-asks
    demo = []
    if profile.get("age"):
        demo.append(f"Age: {profile['age']}")
    if profile.get("gender"):
        demo.append(f"Gender: {profile['gender']}")
    if profile.get("location_region"):
        demo.append(f"Location: {profile['location_region']}")
    mp = _parse_json_field(profile.get("matching_prefs"))
    if mp.get("interested_in"):
        demo.append(f"Looking for: {mp['interested_in']}")
    if mp.get("age_min") is not None and mp.get("age_max") is not None:
        demo.append(f"Partner age range: {mp['age_min']}–{mp['age_max']}")
    if demo:
        parts.append(f"## Demographics\n{', '.join(demo)}")

    # Verbatim ground truth — last 20 things the user actually said (beats wiki if contradicted)
    raw_statements = []
    if profile.get("raw_user_statements"):
        try:
            raw_statements = json.loads(profile["raw_user_statements"])
        except Exception:
            pass
    if raw_statements:
        recent = raw_statements[-20:]
        parts.append(
            f"## What {name} Has Actually Said\n"
            + "\n".join(f"- {s}" for s in recent)
        )

    # LLM wiki — synthesized profile from all sessions
    if profile.get("wiki_about_me"):
        parts.append(f"## About {name}\n{profile['wiki_about_me']}")
    if profile.get("wiki_context"):
        parts.append(f"## {name}'s Current Life Context\n{profile['wiki_context']}")
    if profile.get("wiki_preferences"):
        parts.append(f"## What {name} Is Looking For\n{profile['wiki_preferences']}")
    if profile.get("wiki_matching"):
        parts.append(f"## {name}'s Matching Profile\n{profile['wiki_matching']}")

    # User-written profile fields
    if profile.get("profile_public"):
        parts.append(f"## {name}'s Own Words\n{profile['profile_public']}")
    if profile.get("profile_private"):
        parts.append(f"## {name}'s Private Notes\n{profile['profile_private']}")

    matching_prefs = _parse_json_field(profile.get("matching_prefs"))
    if matching_prefs:
        parts.append(
            f"## Matching Preferences\n{json.dumps(matching_prefs, indent=2)}"
        )

    if profile.get("wiki_profile_structured"):
        parts.append(f"## Structured Match Profile\n{profile['wiki_profile_structured']}")

    profile_answers = _parse_json_field(profile.get("profile_answers"))
    answered_keys = _answered_question_keys_from_profile(profile)
    missing_required = [
        q["id"]
        for q in active_questions
        if q.get("required") and q.get("id") and q["id"] not in answered_keys
    ]
    if missing_required:
        parts.append(
            "## Highest Priority Missing Fields\n"
            + "\n".join(f"- {fid}" for fid in missing_required[:20])
        )

    # Custom skills
    for skill in skills:
        if skill.get("content"):
            parts.append(f"## {skill.get('name', 'Custom Skill')}\n{skill['content']}")

    # Questionnaire — primary objective
    if pending_questions:
        required = [q for q in pending_questions if q.get("category") == "required"]
        deeper = [q for q in pending_questions if q.get("category") == "deeper"]
        matching = [q for q in pending_questions if q.get("category") == "matching_prefs"]
        followups = [q for q in pending_questions if q.get("is_followup")]

        lines = [
            "## Your Primary Objective — The Questionnaire",
            "",
            "Your most important job is to build a complete profile of this person by working through the questions below. Do this naturally — never make it feel like an interview. Follow interesting threads, but always come back to uncovered questions.",
            "",
            "When you're mid-conversation and remember something you want to ask later, call `add_followup_question` to note it. Don't interrupt the current topic.",
        ]

        if required:
            lines.append("\n### Required (cover these early):")
            for q in required:
                lines.append(f"- {q['text']}  [key: {q['key']}]")

        if deeper:
            lines.append("\n### Build a deeper picture (weave in naturally):")
            for q in deeper:
                lines.append(f"- {q['text']}  [key: {q['key']}]")

        if matching:
            lines.append("\n### Matching preferences (get before session ends):")
            for q in matching:
                lines.append(f"- {q['text']}  [key: {q['key']}]")

        if followups:
            lines.append("\n### Your saved follow-ups (from previous conversations):")
            for q in followups:
                lines.append(f"- {q['text']}")

        parts.append("\n".join(lines))
    else:
        parts.append(
            f"## Questionnaire Complete\n\nYou have covered all the key questions about {name}. "
            "Now deepen the conversation and update what you know as things change."
        )

    # Narrative depth prompts from the questionnaire graph.
    # These are the open-ended LLM questions for the user's intent type.
    # Ayma should weave them in naturally — one per conversation, never as a list.
    intent = (matching_prefs.get("intent_type") or "long_term").lower()
    llm_prompts = get_llm_prompts(intent)
    if llm_prompts:
        profile_answers_snapshot = _parse_json_field(profile.get("profile_answers"))
        pending_narratives = [p for p in llm_prompts if not profile_answers_snapshot.get(p["id"])]
        if pending_narratives:
            narrative_lines = [
                "## Narrative Depth — Weave These In",
                "",
                "These open-ended questions surface the deep context that powers matching. "
                "Work them into conversation naturally — one per session, never recited as a list. "
                "Wait for an emotionally resonant moment before asking each one. "
                "When the user gives a real answer, reflect on it briefly, then move on.",
                "",
            ]
            for p in pending_narratives:
                narrative_lines.append(f'- "{p["prompt"]}"  [narrative_id: {p["id"]}]')
            parts.append("\n".join(narrative_lines))

    # Personalized opener
    if profile.get("wiki_about_me") or profile.get("wiki_context"):
        parts.append(
            f"\nThe user's name is {name}. You've talked before — greet them warmly as the friend you've become. "
            "Reference something specific from the profile above to show you remember. "
            "Then continue deepening the conversation naturally."
        )
    else:
        parts.append(
            f"\nThe user's name is {name}. This is your first conversation. "
            "Greet them warmly and start with one genuine, open-ended question — something that invites them to share something real about themselves, "
            "not just facts. Make them feel immediately comfortable and curious to keep talking."
        )

    return "\n\n---\n\n".join(parts)

# ── Helper function to load and parse JSON from Postgres ──────────────────────

def _parse_row(row) -> dict:
    if not row:
        return {}
    res = dict(row)
    # Parse JSONB fields
    for field in ["matching_prefs", "profile_answers", "profile_answers_public", 
                  "profile_answers_private", "profile_answers_sensitive", 
                  "profile_field_visibility", "photo_order", "voice_settings",
                  "location_coords"]:
        if field in res:
            try:
                res[field] = json.loads(res[field]) if isinstance(res[field], str) else res[field]
            except Exception:
                res[field] = [] if field == "photo_order" else {}
    # Convert SQLite boolean integer fields to actual booleans
    for field in ["onboarding_complete", "matching_paused", "preboarding_seen", 
                  "profile_public_locked", "profile_public_user_edited", 
                  "show_simulation_transcript"]:
        if field in res and res[field] is not None:
            res[field] = bool(res[field])
    return res

# ── Bootstrap ─────────────────────────────────────────────────────────────────

@app.post("/bootstrap")
@limiter.limit(RATE_BOOTSTRAP)
async def bootstrap(request: Request, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        profile_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
        if not profile_row:
            display_name = "User"
            try:
                user_record = auth.get_user(uid)
                if user_record.display_name:
                    display_name = user_record.display_name
            except Exception:
                pass
            
            await conn.execute(
                "INSERT INTO users (id, display_name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                uid, display_name
            )
            profile_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
        
        profile = _parse_row(profile_row)
        active_questions = _active_questions_for_profile(profile)
        answered_keys = _answered_question_keys_from_profile(profile)

        # Fetch custom skills
        skills_rows = await conn.fetch(
            "SELECT name, content FROM user_skills WHERE user_id = $1 AND enabled = TRUE",
            uid
        )
        skills = [dict(r) for r in skills_rows]

        # Seed questions if empty
        questions_exist = await conn.fetchval(
            "SELECT EXISTS(SELECT 1 FROM user_questions WHERE user_id = $1)",
            uid
        )
        if not questions_exist:
            to_insert = []
            for q in active_questions:
                qid = q.get("id")
                qtext = q.get("question_text", "")
                category = _question_category(q)
                answered = qid in answered_keys
                
                to_insert.append((
                    uid, qid, qid, qtext, category, 99, answered,
                    datetime.now(timezone.utc).isoformat() if answered else None,
                    False
                ))
            
            if to_insert:
                await conn.executemany("""
                    INSERT INTO user_questions (
                        user_id, question_id, key, text, category, sort_order, answered, answered_at, is_followup
                    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                    ON CONFLICT DO NOTHING
                """, to_insert)

        # Fetch pending questions (unanswered)
        questions_rows = await conn.fetch("""
            SELECT key, text, category, sort_order as "order", is_followup
            FROM user_questions
            WHERE user_id = $1 AND answered = FALSE
            ORDER BY 
              CASE category 
                WHEN 'required' THEN 0 
                WHEN 'deeper' THEN 1 
                WHEN 'matching_prefs' THEN 2 
                ELSE 3 
              END, 
              sort_order
        """, uid)
        pending_questions = [dict(r) for r in questions_rows]

    system_prompt = _build_system_prompt(profile, skills, pending_questions)
    voice_pref = (profile.get("voice_preference") or "").strip()
    if voice_pref.lower() in ("march", "ash", "cove", "ember", "breeze", "fenrir"):
        voice = "Fenrir"
    elif voice_pref.lower() in ("puck", "kore", "aoede"):
        gemini_names = {"puck": "Puck", "kore": "Kore", "aoede": "Aoede"}
        voice = gemini_names[voice_pref.lower()]
    else:
        voice = "Charon"

    setup = {
        "model": f"models/{LIVE_MODEL}",
        "system_instruction": {"parts": [{"text": system_prompt}]},
        "generation_config": {
            "response_modalities": ["AUDIO"],
            "speech_config": {
                "voice_config": {
                    "prebuilt_voice_config": {"voice_name": voice}
                }
            },
        },
        "input_audio_transcription": {},
        "tools": [{
            "functionDeclarations": [{
                "name": "add_followup_question",
                "description": (
                    "Note a question or topic to come back to later, without interrupting "
                    "the current conversation flow. Call this when something interesting "
                    "comes up that you want to explore more deeply in a future turn."
                ),
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "question": {
                            "type": "STRING",
                            "description": "The question or topic to follow up on, as a short reminder to yourself.",
                        }
                    },
                    "required": ["question"],
                },
            }]
        }],
    }

    # Generate LiveKit AccessToken signed with VideoGrants and explicitly
    # dispatch the Ayma agent to the user's room. This avoids depending on
    # automatic dispatch heuristics, which are fragile in production.
    from livekit import api as livekit_api
    from livekit.api import AccessToken, VideoGrants
    from livekit.api.twirp_client import TwirpError
    from agent import AGENT_NAME

    livekit_url = os.environ.get("LIVEKIT_URL", "wss://ayma.livekit.cloud")
    livekit_key = os.environ.get("LIVEKIT_API_KEY", "")
    livekit_secret = os.environ.get("LIVEKIT_API_SECRET", "")

    if not livekit_key or not livekit_secret:
        logger.warning("Missing LIVEKIT_API_KEY or LIVEKIT_API_SECRET during bootstrap.")
        lk_token = ""
    else:
        # Sign the token. Room name is set to the user's uid.
        lk_token = (
            AccessToken(livekit_key, livekit_secret)
            .with_identity(uid)
            .with_name(profile.get("display_name") or "User")
            .with_grants(VideoGrants(
                room_join=True,
                room=uid,
                can_publish=True,
                can_subscribe=True,
                can_publish_data=True,
            ))
            .to_jwt()
        )

        # Ensure a matching agent is explicitly dispatched to this room.
        lkapi = livekit_api.LiveKitAPI(
            livekit_url,
            livekit_key,
            livekit_secret,
        )
        try:
            try:
                existing = await lkapi.agent_dispatch.list_dispatch(room_name=uid)
            except TwirpError as e:
                if e.code == "not_found":
                    existing = []
                else:
                    raise
            if not any(dispatch.agent_name == AGENT_NAME for dispatch in existing):
                await lkapi.agent_dispatch.create_dispatch(
                    livekit_api.CreateAgentDispatchRequest(
                        agent_name=AGENT_NAME,
                        room=uid,
                        metadata=json.dumps({"uid": uid}),
                    )
                )
                logger.info(f"Created LiveKit dispatch for room={uid} agent={AGENT_NAME}")
        except Exception as e:
            logger.exception(f"LiveKit dispatch failed for room={uid}: {e}")
            lk_token = ""
        finally:
            await lkapi.aclose()

    return {
        "websocket_url": livekit_url,
        "token": lk_token,
        "setup": setup,
        "model": LIVE_MODEL,
        "text_model": TEXT_MODEL,
    }

class ChatBody(BaseModel):
    messages: list[dict]
    system_prompt: str | None = None

@app.post("/chat")
@limiter.limit(RATE_CHAT_TEXT)
async def chat_text(body: ChatBody, request: Request, uid: str = Depends(verify_token)):
    contents = []
    for m in body.messages:
        role = "user" if m.get("role") == "user" else "model"
        text = m.get("text", "")
        if text:
            contents.append({"role": role, "parts": [{"text": text}]})
    if not contents:
        raise HTTPException(status_code=400, detail="No messages provided")

    client = google_genai.Client(api_key=_active_key())
    def _generate():
        return client.models.generate_content(
            model=TEXT_MODEL,
            contents=contents,
            config=google_genai_types.GenerateContentConfig(
                system_instruction=body.system_prompt or None,
            ),
        )
    try:
        response = await asyncio.to_thread(_generate)
        return {"reply": response.text or ""}
    except Exception as e:
        if _is_quota_error(e):
            _rotate_key()
            raise HTTPException(status_code=429, detail="Quota exhausted")
        raise HTTPException(status_code=500, detail=str(e))

# ── Consolidated Post-turn Synthesis ──────────────────────────────────────────

CONSOLIDATED_POST_TURN_PROMPT = """You are the memory and profile engine for Ayma, an AI matchmaking companion.

Your job: process this conversation and extract what was learned, updating the user's profile wiki and structured fields.

## Conversation
{conversation}

---

## Part 1: Wiki Memory Update

You maintain 4 running markdown bullet lists for {user_name}. Each is a synthesized, deduplicated fact list.

STRICT RULES:
- Only include facts the USER explicitly stated. Not what the AI said, not inferences.
- Merge new facts with existing ones — don't duplicate. If a fact is already captured, don't write it again.
- If new info UPDATES a previous fact (e.g. they said they're vegetarian now but previously said flexible), update it — don't keep both.
- If the user SOFTENS or EXPANDS a previous preference (e.g. "I used to want only X but now I'm open to Y too"), update the bullet to reflect the evolved stance. Remove the old strict version and write the nuanced one.
  Examples of softening you MUST capture:
  • "ideally South Indian" + "open to outside Tamil if values align" → "prefers South Indian but open to others with strong values"
  • "must be religious" + "not a hard requirement anymore" → "prefer someone religious, but not a dealbreaker"
  • "wants to stay in [city]" + "open to relocation" → "open to relocation for the right person"
- Write in bullet point format: "- [fact]"
- Max sizes: About Me (25 bullets), Life Context (15 bullets), Partner Preferences (25 bullets), Matching Specs (20 bullets)
- Quality bar: each bullet must be a concrete, specific fact. Not vague summaries.
- If nothing new was learned for a section, return the existing list UNCHANGED.

Current Wiki (update these):

[About {user_name}]:
{wiki_about_me}

[{user_name}'s Life Context]:
{wiki_context}

[What {user_name} Is Looking For]:
{wiki_preferences}

[{user_name}'s Matching Specs]:
{wiki_matching}

---

## Part 2: Structured Field Extraction

Extract values for these profile fields if the user explicitly stated them:
{field_catalog}

Only extract if the user clearly stated the value. Confidence "high" = they said it directly. "medium" = it can be reasonably inferred from what they said.

---

## Part 3: Question Coverage

Check which of these unanswered questions were addressed (even partially) in this conversation:
{unanswered_questions_list}

---

## Part 4: Narrative Depth Answers

The following open-ended narrative prompts power the semantic matching engine. Check if the user gave a
meaningful answer to any of them in this conversation. Only capture an answer if the user responded
substantively (2+ sentences of real personal content). A short deflection or "I don't know" is NOT an answer.

{narrative_prompts_list}

For each prompt that received a real answer, capture the user's response as a single coherent paragraph
(preserve their voice — don't over-sanitize). Return the narrative_id and the captured answer.

---

## Part 5: Public Profile Bio

Write a `public_summary` — a 1-2 sentence bio that will appear on the user's PUBLIC dating profile, visible to other users.

Rules for public_summary:
- Write as a warm, third-person description that makes the person sound interesting and approachable
- Focus on: who they are, what they do, where they live, their personality or values
- NEVER include: substance use (drugs, alcohol habits), explicit hookup/sexual preferences, very personal relationship history, anything that would be overly intimate or off-putting if read by a stranger
- Sensitive fields (diet restrictions, religion, substances) should only appear if they are clearly core to the person's identity AND framed positively (e.g. "passionate vegetarian chef" not "doesn't drink and smokes weed")
- If in doubt whether something is appropriate for a public profile, leave it out
- Aim for the tone of a good Hinge or Bumble bio — human, specific, inviting

EXAMPLE OUTPUT (replace all values with real data — do not copy these strings):
{{
  "wiki_updates": {{
    "about_me": "- She is 28 years old\\n- She is a software engineer at a fintech startup\\n- She is Tamil Brahmin and vegetarian",
    "context": "- She is based in Toronto and plans to stay long-term\\n- Her family is traditional and will be involved in major decisions",
    "preferences": "- She wants to marry someone South Indian, ideally Tamil\\n- Horoscope matching is important to her and her family",
    "matching": "- Age preference: 28-35\\n- Location: Toronto or willing to relocate within Canada"
  }},
  "extracted_answers": [
    {{"id": "diet", "value": "vegetarian", "confidence": "high"}},
    {{"id": "alcohol_status", "value": "no", "confidence": "high"}}
  ],
  "sensitive_public_opt_in": [],
  "public_summary": "Priya is a 28-year-old software engineer in Toronto looking for a serious relationship with a South Indian partner who values family.",
  "answered_question_keys": ["diet", "alcohol_status", "religion"],
  "narrative_answers": [
    {{"id": "lt_crisis_response", "answer": "She said she'd want to face any crisis practically first — make a plan, assign roles, deal with emotions after the dust settles. She imagines her partner being the one who keeps her grounded when she goes into fix-it mode and forgets to feel things."}}
  ]
}}

Now return ONLY the real JSON for this conversation. No prose, no markdown wrapping, no copying of example values.
"""

class PostTurnRequest(BaseModel):
    session_id: str
    messages: list[dict]  # [{"role": "user"|"model", "text": "..."}]

def _render_structured_wiki(profile_answers: dict) -> str:
    by_section: dict[str, list[tuple[str, object]]] = {}
    for field_id, value in profile_answers.items():
        meta = PROFILE_FIELD_META.get(field_id, {})
        section = meta.get("section", "uncategorized")
        by_section.setdefault(section, []).append((field_id, value))

    # Keep schema order for sections/fields
    section_order = PUBLIC_PAYLOAD_ORDER or list(by_section.keys())
    q_order = [q.get("id") for q in ACTIVE_QUESTION_BANK]

    parts: list[str] = []
    for section in section_order:
        rows = by_section.get(section, [])
        if not rows:
            continue
        parts.append(f"## {section}")
        rows = sorted(rows, key=lambda kv: q_order.index(kv[0]) if kv[0] in q_order else 9999)
        for fid, val in rows:
            if isinstance(val, (dict, list)):
                vtxt = json.dumps(val, ensure_ascii=False)
            else:
                vtxt = str(val)
            parts.append(f"- {fid}: {vtxt}")
        parts.append("")
    return "\n".join(parts).strip()

@app.post("/post-turn")
@limiter.limit(RATE_POST_TURN)
async def post_turn(request: Request, body: PostTurnRequest, uid: str = Depends(verify_token)):
    if not body.messages:
        return {"updated": False}

    conversation = "\n".join(
        f"{m['role'].upper()}: {m['text']}" for m in body.messages[-10:]
    )

    pool = app.state.pool
    async with pool.acquire() as conn:
        profile_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
        if not profile_row:
            return {"updated": False}
        profile = _parse_row(profile_row)
        active_questions = _active_questions_for_profile(profile)
        user_name = profile.get("display_name") or "User"

        # Store verbatim statements
        user_lines = [m["text"] for m in body.messages[-10:] if m.get("role") == "user" and m.get("text", "").strip()]
        raw_user_statements_str = "[]"
        if user_lines:
            try:
                existing_statements = json.loads(profile.get("raw_user_statements") or "[]")
            except Exception:
                existing_statements = []
            combined = existing_statements + user_lines
            raw_user_statements_str = json.dumps(combined[-100:])
            await conn.execute("UPDATE users SET raw_user_statements = $1 WHERE id = $2", raw_user_statements_str, uid)

        # Fetch unanswered questions for the prompt checklist
        questions_rows = await conn.fetch("""
            SELECT key, text 
            FROM user_questions 
            WHERE user_id = $1 AND answered = FALSE AND is_followup = FALSE
        """, uid)
        pending_questions = [dict(r) for r in questions_rows]

        # Assemble catalog & pending lists
        field_catalog = "\n".join(
            f"- {q.get('id')}: {q.get('question_text')}"
            for q in active_questions
            if q.get("id")
        )
        unanswered_questions_list = "\n".join(
            f"- {q['key']}: {q['text']}" for q in pending_questions
        )

        # Narrative prompts from questionnaire graph — only include ones not yet answered
        intent = (_parse_json_field(profile.get("matching_prefs")).get("intent_type") or "long_term").lower()
        all_narratives = get_llm_prompts(intent)
        profile_answers_now = _parse_json_field(profile.get("profile_answers"))
        pending_narratives = [p for p in all_narratives if not profile_answers_now.get(p["id"])]
        if pending_narratives:
            narrative_prompts_list = "\n".join(
                f'- [narrative_id: {p["id"]}] "{p["prompt"]}"'
                for p in pending_narratives
            )
        else:
            narrative_prompts_list = "(all narrative prompts answered — no action needed)"

        prompt = CONSOLIDATED_POST_TURN_PROMPT.format(
            conversation=conversation,
            user_name=user_name,
            wiki_about_me=profile.get("wiki_about_me") or "(empty)",
            wiki_context=profile.get("wiki_context") or "(empty)",
            wiki_preferences=profile.get("wiki_preferences") or "(empty)",
            wiki_matching=profile.get("wiki_matching") or "(empty)",
            field_catalog=field_catalog,
            unanswered_questions_list=unanswered_questions_list,
            narrative_prompts_list=narrative_prompts_list,
        )

        # Call Gemini with automatic key-rotation fallback on quota exhaustion
        payload = {}
        try:
            raw = await _gemini_call(
                TEXT_MODEL, prompt,
                generation_config={"response_mime_type": "application/json"},
            )
            payload = json.loads(raw)
        except Exception as e:
            logger.warning(f"[post-turn] Gemini extraction failed: {type(e).__name__}: {e}")

        wiki_updates = payload.get("wiki_updates") or {}
        # Use `or` fallback so an empty string from Gemini preserves existing wiki
        wiki_about_me = wiki_updates.get("about_me") or profile.get("wiki_about_me") or ""
        wiki_context = wiki_updates.get("context") or profile.get("wiki_context") or ""
        wiki_preferences = wiki_updates.get("preferences") or profile.get("wiki_preferences") or ""
        wiki_matching = wiki_updates.get("matching") or profile.get("wiki_matching") or ""

        extracted_answers = payload.get("extracted_answers") or []
        sensitive_public_opt_in = set(payload.get("sensitive_public_opt_in") or [])
        extracted_summary = (payload.get("public_summary") or "").strip()
        answered_keys = set(payload.get("answered_question_keys") or [])

        existing_answers = profile.get("profile_answers") or {}
        public_map = profile.get("profile_answers_public") or {}
        private_map = profile.get("profile_answers_private") or {}
        sensitive_map = profile.get("profile_answers_sensitive") or {}
        visibility_map = profile.get("profile_field_visibility") or {}

        for item in extracted_answers:
            field_id = item.get("id")
            if not field_id or field_id not in PROFILE_FIELD_META:
                continue
            if "value" not in item:
                continue
            value = item["value"]
            meta = PROFILE_FIELD_META.get(field_id, {})
            sensitive = bool(meta.get("sensitive_flag"))

            existing_answers[field_id] = value
            if sensitive:
                sensitive_map[field_id] = value
                public_allowed = field_id in sensitive_public_opt_in
                visibility_map[field_id] = "public" if public_allowed else "private"
                if public_allowed:
                    public_map[field_id] = value
                else:
                    public_map.pop(field_id, None)
                    private_map[field_id] = value
            else:
                visibility_map[field_id] = "public"
                public_map[field_id] = value
                private_map.pop(field_id, None)

        # Save narrative answers from questionnaire graph prompts.
        # These go into profile_answers keyed by narrative_id, and are also
        # appended to wiki_matching so the matching engine can embed them.
        narrative_answers = payload.get("narrative_answers") or []
        valid_narrative_ids = {p["id"] for p in all_narratives}
        for item in narrative_answers:
            nid = item.get("id")
            answer_text = (item.get("answer") or "").strip()
            if nid and nid in valid_narrative_ids and answer_text:
                existing_answers[nid] = answer_text
                # Surface the answer in wiki_matching so it feeds the embedding
                label = next((p["prompt"][:60] for p in all_narratives if p["id"] == nid), nid)
                entry = f"\n- [{nid}] {answer_text}"
                if entry not in wiki_matching:
                    wiki_matching = (wiki_matching or "") + entry

        structured_wiki = _render_structured_wiki(existing_answers)

        profile_update_args = [
            wiki_about_me, wiki_context, wiki_preferences, wiki_matching,
            json.dumps(existing_answers), json.dumps(public_map), json.dumps(private_map),
            json.dumps(sensitive_map), json.dumps(visibility_map), structured_wiki,
            extracted_summary or profile.get("profile_ai_observations") or "",
            extracted_summary or profile.get("profile_public") or "",
            raw_user_statements_str, uid
        ]

        await conn.execute("""
            UPDATE users SET
                wiki_about_me = $1,
                wiki_context = $2,
                wiki_preferences = $3,
                wiki_matching = $4,
                profile_answers = $5,
                profile_answers_public = $6,
                profile_answers_private = $7,
                profile_answers_sensitive = $8,
                profile_field_visibility = $9,
                wiki_profile_structured = $10,
                profile_ai_observations = $11,
                profile_public = $12,
                raw_user_statements = $13,
                updated_at = NOW()
            WHERE id = $14
        """, *profile_update_args)

        # Mark questions as answered in Database
        all_answered_keys = answered_keys | set(existing_answers.keys())
        if all_answered_keys:
            await conn.execute("""
                UPDATE user_questions
                SET answered = TRUE, answered_at = NOW()
                WHERE user_id = $1 AND key = ANY($2) AND answered = FALSE
            """, uid, list(all_answered_keys))

        # Add audit memory log
        await conn.execute("""
            INSERT INTO user_memories (user_id, text, session_id)
            VALUES ($1, $2, $3)
        """, uid, conversation, body.session_id)

    # Re-embed matching wiki in the background so pgvector stays fresh without
    # blocking the post-turn response.
    asyncio.create_task(_refresh_wiki_embedding(uid, app.state.pool))

    return {"updated": True}

# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok"}


# ── Admin Endpoints ───────────────────────────────────────────────────────────

@app.get("/admin/users")
async def admin_list_users(
    query: str | None = None,
    gender: str | None = None,
    community_profile: str | None = None,
    intent_type: str | None = None,
    onboarding_complete: bool | None = None,
    matching_paused: bool | None = None,
    has_photos: bool | None = None,
    has_matches: bool | None = None,
    has_messages: bool | None = None,
    min_age: int | None = None,
    max_age: int | None = None,
    limit: int = 100,
    admin_ok: bool = Depends(verify_admin),
):
    del admin_ok
    pool = app.state.pool
    args: list[Any] = []
    where: list[str] = []

    def bind(value: Any) -> str:
        args.append(value)
        return f"${len(args)}"

    if query:
        token = bind(f"%{query.strip()}%")
        where.append(
            f"(u.id ILIKE {token} OR u.display_name ILIKE {token} OR u.profile_public ILIKE {token} OR u.location_region ILIKE {token})"
        )
    if gender:
        where.append(f"u.gender = {bind(gender)}")
    if community_profile:
        where.append(f"u.community_profile = {bind(community_profile)}")
    if intent_type:
        where.append(f"COALESCE(u.matching_prefs->>'intent_type', '') = {bind(intent_type)}")
    if onboarding_complete is not None:
        where.append(f"u.onboarding_complete = {bind(onboarding_complete)}")
    if matching_paused is not None:
        where.append(f"u.matching_paused = {bind(matching_paused)}")
    if min_age is not None:
        where.append(f"u.age >= {bind(min_age)}")
    if max_age is not None:
        where.append(f"u.age <= {bind(max_age)}")
    if has_photos is not None:
        exists_clause = "EXISTS (SELECT 1 FROM user_media um WHERE um.user_id = u.id)"
        where.append(exists_clause if has_photos else f"NOT {exists_clause}")
    if has_matches is not None:
        exists_clause = "EXISTS (SELECT 1 FROM matches mt WHERE mt.user_a = u.id OR mt.user_b = u.id)"
        where.append(exists_clause if has_matches else f"NOT {exists_clause}")
    if has_messages is not None:
        exists_clause = "EXISTS (SELECT 1 FROM messages msg WHERE msg.from_user_id = u.id OR msg.to_user_id = u.id)"
        where.append(exists_clause if has_messages else f"NOT {exists_clause}")

    safe_limit = max(1, min(limit, 500))
    sql = f"""
        SELECT
            u.id,
            u.display_name,
            u.age,
            u.gender,
            u.location_region,
            u.community_profile,
            u.onboarding_complete,
            u.matching_paused,
            u.profile_public,
            u.updated_at,
            COALESCE(u.matching_prefs->>'intent_type', '') AS intent_type,
            (SELECT COUNT(*) FROM user_media um WHERE um.user_id = u.id) AS photo_count,
            (SELECT COUNT(*) FROM user_memories mem WHERE mem.user_id = u.id) AS memory_count,
            (SELECT COUNT(*) FROM matches mt WHERE mt.user_a = u.id OR mt.user_b = u.id) AS match_count,
            (SELECT COUNT(*) FROM messages msg WHERE msg.from_user_id = u.id OR msg.to_user_id = u.id) AS message_count,
            (SELECT COUNT(*) FROM notifications n WHERE n.user_id = u.id AND n.read = FALSE) AS unread_notifications
        FROM users u
        {"WHERE " + " AND ".join(where) if where else ""}
        ORDER BY u.updated_at DESC, u.created_at DESC
        LIMIT {safe_limit}
    """

    async with pool.acquire() as conn:
        rows = await conn.fetch(sql, *args)
    return _serialize_records(rows)


@app.get("/admin/users/{target_uid}")
async def admin_get_user_detail(target_uid: str, admin_ok: bool = Depends(verify_admin)):
    del admin_ok
    pool = app.state.pool
    async with pool.acquire() as conn:
        user_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", target_uid)
        if not user_row:
            raise HTTPException(status_code=404, detail="User not found")

        skills_rows = await conn.fetch(
            "SELECT user_id, skill_id, name, content, enabled FROM user_skills WHERE user_id = $1 ORDER BY skill_id ASC",
            target_uid,
        )
        questions_rows = await conn.fetch(
            """
            SELECT user_id, question_id, key, text, category, sort_order, answered, answered_at, is_followup
            FROM user_questions
            WHERE user_id = $1
            ORDER BY answered ASC, is_followup ASC, sort_order ASC, question_id ASC
            """,
            target_uid,
        )
        memories_rows = await conn.fetch(
            """
            SELECT id, user_id, text, session_id, created_at
            FROM user_memories
            WHERE user_id = $1
            ORDER BY created_at DESC, id DESC
            """,
            target_uid,
        )
        media_rows = await conn.fetch(
            """
            SELECT id, user_id, photo_url, caption, created_at
            FROM user_media
            WHERE user_id = $1
            ORDER BY created_at DESC, id DESC
            """,
            target_uid,
        )
        notifications_rows = await conn.fetch(
            """
            SELECT id, user_id, type, title, body, meta, read, created_at
            FROM notifications
            WHERE user_id = $1
            ORDER BY created_at DESC, id DESC
            """,
            target_uid,
        )
        messages_rows = await conn.fetch(
            """
            SELECT
                m.id,
                m.from_user_id,
                m.to_user_id,
                m.text,
                m.read,
                m.created_at,
                CASE
                    WHEN m.from_user_id = $1 THEN m.to_user_id
                    ELSE m.from_user_id
                END AS counterpart_user_id,
                u.display_name AS counterpart_display_name
            FROM messages m
            LEFT JOIN users u
                ON u.id = CASE WHEN m.from_user_id = $1 THEN m.to_user_id ELSE m.from_user_id END
            WHERE m.from_user_id = $1 OR m.to_user_id = $1
            ORDER BY m.created_at DESC, m.id DESC
            """,
            target_uid,
        )
        match_rows = await conn.fetch(
            """
            SELECT
                m.*,
                CASE WHEN m.user_a = $1 THEN m.user_b ELSE m.user_a END AS other_user_id,
                u.display_name AS other_display_name
            FROM matches m
            LEFT JOIN users u
                ON u.id = CASE WHEN m.user_a = $1 THEN m.user_b ELSE m.user_a END
            WHERE m.user_a = $1 OR m.user_b = $1
            ORDER BY m.updated_at DESC, m.created_at DESC, m.id DESC
            """,
            target_uid,
        )

        match_ids = [row["id"] for row in match_rows]
        simulation_rows = []
        if match_ids:
            simulation_rows = await conn.fetch(
                """
                SELECT id, match_id, sender_uid, turn_index, message_text, created_at
                FROM match_simulations
                WHERE match_id = ANY($1::int[])
                ORDER BY match_id ASC, turn_index ASC, created_at ASC
                """,
                match_ids,
            )

    simulations_by_match: dict[int, list[dict]] = {}
    for row in simulation_rows:
        data = {k: _serialize_value(v) for k, v in dict(row).items()}
        simulations_by_match.setdefault(int(row["match_id"]), []).append(data)

    serialized_matches = []
    for row in match_rows:
        record = {k: _serialize_value(v) for k, v in dict(row).items()}
        record["simulation"] = simulations_by_match.get(int(row["id"]), [])
        serialized_matches.append(record)

    dm_threads: dict[str, dict[str, Any]] = {}
    for row in messages_rows:
        message = {k: _serialize_value(v) for k, v in dict(row).items()}
        counterpart_id = str(message["counterpart_user_id"])
        thread = dm_threads.setdefault(counterpart_id, {
            "counterpart_user_id": counterpart_id,
            "counterpart_display_name": message.get("counterpart_display_name") or "",
            "messages": [],
        })
        thread["messages"].append(message)

    return {
        "user": {k: _serialize_value(v) for k, v in dict(user_row).items()},
        "stats": {
            "skills": len(skills_rows),
            "questions": len(questions_rows),
            "memories": len(memories_rows),
            "media": len(media_rows),
            "notifications": len(notifications_rows),
            "messages": len(messages_rows),
            "matches": len(match_rows),
        },
        "agent_data_notes": {
            "full_agent_chat_transcripts_available": False,
            "stored_agent_history_source": "user_memories stores post-turn conversation audit snapshots; raw_user_statements stores verbatim user lines; user_media stores uploaded photos",
        },
        "skills": _serialize_records(skills_rows),
        "questions": _serialize_records(questions_rows),
        "memories": _serialize_records(memories_rows),
        "media": _serialize_records(media_rows),
        "notifications": _serialize_records(notifications_rows),
        "messages": _serialize_records(messages_rows),
        "dm_threads": list(dm_threads.values()),
        "matches": serialized_matches,
    }

# ── Wiki Correct Endpoint ──────────────────────────────────────────────────────

_WIKI_SECTION_COLUMNS = {
    "about_me": "wiki_about_me",
    "context": "wiki_context",
    "preferences": "wiki_preferences",
    "matching": "wiki_matching",
}

class WikiCorrectBody(BaseModel):
    section: str
    feedback: str

@app.post("/wiki/correct")
async def wiki_correct(body: WikiCorrectBody, uid: str = Depends(verify_token)):
    if body.section not in _WIKI_SECTION_COLUMNS:
        raise HTTPException(status_code=400, detail=f"Invalid section. Must be one of: {', '.join(_WIKI_SECTION_COLUMNS)}")

    column = _WIKI_SECTION_COLUMNS[body.section]
    pool = app.state.pool

    async with pool.acquire() as conn:
        row = await conn.fetchrow(f"SELECT {column} FROM users WHERE id = $1", uid)
        current_content = (row[column] if row and row[column] else "") if row else ""

    prompt = (
        f"You maintain this user's private profile wiki section. "
        f"The user says their correction: '{body.feedback}'. "
        f"Update the wiki section preserving existing accurate facts, removing/correcting what the user flagged. "
        f"Return JSON: {{\"updated_wiki\": \"...\"}}. "
        f"Current wiki:\n{current_content}"
    )

    try:
        raw = await _gemini_call(
            TEXT_MODEL, prompt,
            generation_config={"response_mime_type": "application/json"},
        )
        payload = json.loads(raw)
    except Exception as e:
        logger.warning(f"[wiki/correct] Gemini call failed: {type(e).__name__}: {e}")
        raise HTTPException(status_code=500, detail="Failed to process correction")

    updated_wiki = payload.get("updated_wiki", current_content)

    async with pool.acquire() as conn:
        await conn.execute(
            f"UPDATE users SET {column} = $1 WHERE id = $2",
            updated_wiki, uid,
        )

    asyncio.create_task(_refresh_wiki_embedding(uid, app.state.pool))

    return {"section": body.section, "content": updated_wiki}

# ── Profile Endpoints ──────────────────────────────────────────────────────────

class ProfileUpdateBody(BaseModel):
    display_name: str | None = None
    age: int | None = None
    gender: str | None = None
    location_region: str | None = None
    location_coords: dict | None = None
    onboarding_complete: bool | None = None
    matching_paused: bool | None = None
    preboarding_seen: bool | None = None
    photo_order: list | None = None
    voice_settings: dict | None = None
    profile_public: str | None = None
    profile_public_locked: bool | None = None
    profile_public_user_edited: bool | None = None
    profile_public_pending: str | None = None
    community_profile: str | None = None
    agent_name: str | None = None
    voice_preference: str | None = None
    matching_prefs: dict | None = None

@app.get("/profile")
async def get_profile(uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
        if not row:
            display_name = "User"
            try:
                user_record = auth.get_user(uid)
                if user_record.display_name:
                    display_name = user_record.display_name
            except Exception:
                pass
            await conn.execute("INSERT INTO users (id, display_name) VALUES ($1, $2) ON CONFLICT DO NOTHING", uid, display_name)
            row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
        return _parse_row(row)

@app.post("/profile")
async def update_profile(body: ProfileUpdateBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    fields = body.model_dump(exclude_unset=True)
    if not fields:
        return {"success": True}

    set_clauses = []
    args = []
    idx = 1
    for k, v in fields.items():
        # Handle maps/lists to JSON strings
        if k in ("photo_order", "voice_settings", "matching_prefs", "location_coords"):
            v = json.dumps(v)
        set_clauses.append(f"{k} = ${idx}")
        args.append(v)
        idx += 1
    
    args.append(uid)
    query = f"UPDATE users SET {', '.join(set_clauses)}, updated_at = NOW() WHERE id = ${idx}"
    
    async with pool.acquire() as conn:
        existing = await conn.fetchval("SELECT 1 FROM users WHERE id = $1", uid)
        if not existing:
            display_name = fields.get("display_name") or "User"
            try:
                user_record = auth.get_user(uid)
                if user_record.display_name and "display_name" not in fields:
                    display_name = user_record.display_name
            except Exception:
                pass
            await conn.execute(
                "INSERT INTO users (id, display_name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                uid,
                display_name,
            )
        await conn.execute(query, *args)
    return {"success": True}

@app.get("/profile/{userId}/public")
async def get_public_profile(userId: str, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT id, display_name, age, gender, location_region, profile_public, photo_order FROM users WHERE id = $1", userId)
        if not row:
            raise HTTPException(status_code=404, detail="Public profile not found")
        data = dict(row)
        
        # Get photos from user_media
        media_rows = await conn.fetch(f"SELECT photo_url FROM user_media WHERE user_id = $1 ORDER BY created_at DESC LIMIT {MATCHES_MEDIA_LIMIT}", userId)
        photos = [r["photo_url"] for r in media_rows]
        data["photos"] = photos
        
        # Order photos according to saved photo_order
        photo_order = []
        if data.get("photo_order"):
            try:
                photo_order = json.loads(data["photo_order"]) if isinstance(data["photo_order"], str) else data["photo_order"]
            except Exception:
                pass
        
        if photo_order:
            rank = {url: i for i, url in enumerate(photo_order)}
            photos.sort(key=lambda u: rank.get(u, 999999))
            data["photos"] = photos
            
        data.pop("photo_order", None)
        return data

@app.get("/insights")
async def get_insights(uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT wiki_about_me, wiki_preferences, wiki_context, wiki_matching, profile_public, updated_at FROM users WHERE id = $1", uid
        )
        if not row:
            return {}
        profile = dict(row)

        media_rows = await conn.fetch(f"SELECT photo_url, caption, created_at FROM user_media WHERE user_id = $1 ORDER BY created_at DESC LIMIT {INSIGHTS_MEDIA_LIMIT}", uid)

        media_lines = []
        for mr in media_rows:
            try:
                date_str = mr["created_at"].strftime("%Y-%m-%d")
            except Exception:
                date_str = str(mr["created_at"])[:10]
            line = f"- [{date_str}]({mr['photo_url']})"
            if mr["caption"]:
                line += f"\n  {mr['caption']}"
            media_lines.append(line)

        updated_at = str(profile.get("updated_at") or "")
        return {
            "about_me": profile.get("wiki_about_me") or "",
            "about_me_updated_at": updated_at,
            "preferences": profile.get("wiki_preferences") or "",
            "preferences_updated_at": updated_at,
            "context": profile.get("wiki_context") or "",
            "context_updated_at": updated_at,
            "matching": profile.get("wiki_matching") or "",
            "matching_updated_at": updated_at,
            "media": "\n".join(media_lines),
            "public_profile": profile.get("profile_public") or ""
        }

# ── Matches Endpoints ──────────────────────────────────────────────────────────

class MatchStatusBody(BaseModel):
    status: str

@app.get("/matches")
async def get_matches(uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        # Load all matches joined with candidate info
        rows = await conn.fetch("""
            SELECT m.id, m.user_a, m.user_b, m.score, m.rationale, m.summary_a, m.summary_b, m.status, m.show_simulation_transcript,
                   u.id as other_id, u.display_name as other_display_name, u.age as other_age, u.gender as other_gender, u.location_region as other_location_region, u.profile_public as other_profile_public
            FROM matches m
            JOIN users u ON (m.user_a = u.id OR m.user_b = u.id)
            WHERE (m.user_a = $1 OR m.user_b = $1) AND u.id != $1
            ORDER BY m.updated_at DESC
        """, uid)
        
        matches = []
        for r in rows:
            m = dict(r)
            # Retrieve photo urls for user
            media_rows = await conn.fetch("SELECT photo_url FROM user_media WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1", m["other_id"])
            m["other_photo_url"] = media_rows[0]["photo_url"] if media_rows else ""
            matches.append(m)
        return matches

@app.post("/matches/{match_id}/status")
async def update_match_status(match_id: int, body: MatchStatusBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute("UPDATE matches SET status = $1, updated_at = NOW() WHERE id = $2 AND (user_a = $3 OR user_b = $3)", body.status, match_id, uid)
    return {"success": True}

# ── Notifications Endpoints ───────────────────────────────────────────────────

@app.get("/notifications")
async def get_notifications(uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        rows = await conn.fetch(f"SELECT id, user_id, type, title, body, meta, read, created_at FROM notifications WHERE user_id = $1 ORDER BY created_at DESC LIMIT {NOTIFICATIONS_LIMIT}", uid)
        notifs = []
        for r in rows:
            n = dict(r)
            try:
                n["meta"] = json.loads(n["meta"]) if isinstance(n["meta"], str) else n["meta"]
            except Exception:
                n["meta"] = {}
            n["id"] = str(n["id"]) # stringify ID for Flutter model parsing
            n["created_at"] = n["created_at"].isoformat()
            notifs.append(n)
        return notifs

@app.post("/notifications/{notif_id}/read")
async def mark_notification_read(notif_id: int, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute("UPDATE notifications SET read = TRUE WHERE id = $1 AND user_id = $2", notif_id, uid)
    return {"success": True}

@app.post("/notifications/read-all")
async def mark_all_notifications_read(uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute("UPDATE notifications SET read = TRUE WHERE user_id = $1 AND read = FALSE", uid)
    return {"success": True}

# ── Profile Answers & Questions Checklist ──────────────────────────────────────

class ProfileAnswerBody(BaseModel):
    field_id: str
    value: Any

class FollowupQuestionBody(BaseModel):
    question: str

@app.get("/profile/answers")
async def get_profile_answers(uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        val = await conn.fetchval("SELECT profile_answers FROM users WHERE id = $1", uid)
        if not val: return {}
        return json.loads(val) if isinstance(val, str) else val

@app.post("/profile/answers")
async def save_profile_answer(body: ProfileAnswerBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT profile_answers, profile_answers_public, profile_answers_private, profile_answers_sensitive, profile_field_visibility FROM users WHERE id = $1", uid)
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        
        def parse_jsonb(v):
            if not v: return {}
            return json.loads(v) if isinstance(v, str) else v

        profile_answers = parse_jsonb(row["profile_answers"])
        public_map = parse_jsonb(row["profile_answers_public"])
        private_map = parse_jsonb(row["profile_answers_private"])
        sensitive_map = parse_jsonb(row["profile_answers_sensitive"])
        visibility_map = parse_jsonb(row["profile_field_visibility"])

        field_id = body.field_id
        value = body.value
        meta = PROFILE_FIELD_META.get(field_id, {})
        sensitive = bool(meta.get("sensitive_flag"))

        profile_answers[field_id] = value
        if sensitive:
            sensitive_map[field_id] = value
            # default visibility for sensitive is private
            visibility_map[field_id] = "private"
            private_map[field_id] = value
            public_map.pop(field_id, None)
        else:
            visibility_map[field_id] = "public"
            public_map[field_id] = value
            private_map.pop(field_id, None)

        structured_wiki = _render_structured_wiki(profile_answers)

        await conn.execute("""
            UPDATE users SET
                profile_answers = $1,
                profile_answers_public = $2,
                profile_answers_private = $3,
                profile_answers_sensitive = $4,
                profile_field_visibility = $5,
                wiki_profile_structured = $6,
                updated_at = NOW()
            WHERE id = $7
        """, json.dumps(profile_answers), json.dumps(public_map), json.dumps(private_map), 
        json.dumps(sensitive_map), json.dumps(visibility_map), structured_wiki, uid)

        # Mark corresponding checklist item as answered
        await conn.execute("""
            UPDATE user_questions
            SET answered = TRUE, answered_at = NOW()
            WHERE user_id = $1 AND key = $2
        """, uid, field_id)

    return {"success": True}

@app.get("/questions/pending")
async def get_pending_questions(uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT question_id, key, text, category, sort_order as "order", is_followup 
            FROM user_questions 
            WHERE user_id = $1 AND answered = FALSE
            ORDER BY sort_order ASC
        """, uid)
        return [dict(r) for r in rows]

@app.post("/questions/followup")
async def add_followup_question(body: FollowupQuestionBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    qid = f"followup_{int(datetime.now().timestamp())}"
    async with pool.acquire() as conn:
        await conn.execute("""
            INSERT INTO user_questions (user_id, question_id, key, text, category, is_followup, sort_order)
            VALUES ($1, $2, $3, $4, 'followup', TRUE, 1)
        """, uid, qid, qid, body.question)
    return {"success": True}

@app.post("/questions/{qid}/answered")
async def mark_question_answered(qid: str, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute("UPDATE user_questions SET answered = TRUE, answered_at = NOW() WHERE user_id = $1 AND question_id = $2", uid, qid)
    return {"success": True}

# ── Explore ───────────────────────────────────────────────────────────────────

@app.get("/explore")
async def explore(gender: str | None = None, ageMin: int | None = None, ageMax: int | None = None, query: str | None = None, uid: str = Depends(verify_token)):
    pool = app.state.pool
    sql = "SELECT id, display_name, age, gender, location_region, profile_public FROM users WHERE onboarding_complete = TRUE AND id != $1"
    args = [uid]
    idx = 2
    
    if gender:
        sql += f" AND gender = ${idx}"
        args.append(gender)
        idx += 1
    if ageMin is not None:
        sql += f" AND age >= ${idx}"
        args.append(ageMin)
        idx += 1
    if ageMax is not None:
        sql += f" AND age <= ${idx}"
        args.append(ageMax)
        idx += 1
    if query:
        sql += f" AND (display_name ILIKE ${idx} OR profile_public ILIKE ${idx})"
        args.append(f"%{query}%")
        idx += 1
        
    sql += f" LIMIT {EXPLORE_LIMIT}"
    
    async with pool.acquire() as conn:
        rows = await conn.fetch(sql, *args)
        people = []
        for r in rows:
            p = dict(r)
            # Retrieve single photo for preview
            media_rows = await conn.fetch("SELECT photo_url FROM user_media WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1", p["id"])
            p["photo_url"] = media_rows[0]["photo_url"] if media_rows else ""
            people.append(p)
        return people

# ── User Media Endpoints ───────────────────────────────────────────────────────

class MediaBody(BaseModel):
    photo_url: str
    caption: str | None = None

class MediaDeleteBody(BaseModel):
    photo_url: str

@app.post("/media")
async def save_media_record(body: MediaBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute("INSERT INTO user_media (user_id, photo_url, caption) VALUES ($1, $2, $3)", uid, body.photo_url, body.caption)
    return {"success": True}

@app.delete("/media")
async def delete_media_by_url(body: MediaDeleteBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute("DELETE FROM user_media WHERE user_id = $1 AND photo_url = $2", uid, body.photo_url)
    return {"success": True}

class AnalyzePhotosBody(BaseModel):
    photo_urls: list[str]

_SAFETY_PROMPT = (
    "Is this image safe for a dating app? Check for explicit nudity, graphic violence, "
    "or hate symbols. Respond with JSON only: "
    '{"safe": true or false, "reason": "one sentence if unsafe, else empty string"}'
)

async def _is_photo_safe(url: str) -> tuple[bool, str]:
    try:
        raw = await _gemini_call(TEXT_MODEL, [_SAFETY_PROMPT, {"url": url}],
                                  generation_config={"response_mime_type": "application/json"})
        data = json.loads(raw)
        return bool(data.get("safe", True)), data.get("reason", "")
    except Exception:
        return True, ""  # fail open — don't block on moderation errors

@app.post("/profile/analyze-photos")
@limiter.limit(RATE_ANALYZE_PHOTOS)
async def analyze_photos(request: Request, body: AnalyzePhotosBody, uid: str = Depends(verify_token)):
    """Use Gemini Vision to understand the user's appearance from their photos,
    then store a brief appearance note in wiki_about_me."""
    if not body.photo_urls:
        return {"success": False, "reason": "no photos"}
    # Safety check: scan each photo before processing
    for url in body.photo_urls:
        safe, reason = await _is_photo_safe(url)
        if not safe:
            logger.warning(f"[moderation] unsafe photo for {uid}: {reason}")
            pool = app.state.pool
            async with pool.acquire() as conn:
                await conn.execute(
                    "UPDATE users SET matching_paused = TRUE WHERE id = $1", uid
                )
            raise HTTPException(status_code=422, detail=f"Photo flagged: {reason}")
    try:
        photo_prompt = (
            "You are an honest, tactful personal matchmaker reviewing a client's photos. "
            "Your job is to give them a real, useful assessment — like a trusted friend who wants them to "
            "put their best foot forward with matches. Be specific, honest, and kind but NOT flattering.\n\n"
            "Analyze the photo(s) and produce a structured assessment covering:\n"
            "1. Overall score: X.X/10 with a one-word label (e.g. Above Average, Strong, Solid, Needs Work)\n"
            "2. Key strengths: 2-3 specific things that stand out positively (bone structure, grooming, style, presence, hair, etc.)\n"
            "3. Areas to improve: 2-3 honest, specific things they could work on (skin texture, beard neckline, hair styling, posture, dark circles, clothing, etc.)\n"
            "4. Best feature: one thing\n"
            "5. One-sentence overall impression a potential match would have\n\n"
            "Do NOT mention race or ethnicity. Be honest — if they score a 6, say 6. "
            "Format as a clean bullet list. No preamble.\n\n"
            "Example format:\n"
            "- score: 7.2/10 — Strong\n"
            "- strengths: defined jawline; full natural hair with good volume; well-groomed beard\n"
            "- improve: under-eye darkness worth addressing; beard neckline could be cleaner; skin texture uneven\n"
            "- best feature: jawline and bone structure\n"
            "- impression: confident, grounded look — approachable with a masculine edge"
        )
        parts = [photo_prompt]
        for url in body.photo_urls[:PHOTO_ANALYSIS_MAX]:
            parts.append({"url": url})
        description = ""
        for attempt in range(len(_API_KEYS)):
            try:
                model = genai.GenerativeModel(TEXT_MODEL)
                resp = model.generate_content(parts)
                description = resp.text.strip() if resp and resp.text else ""
                break
            except Exception as e:
                if _is_quota_error(e) and attempt < len(_API_KEYS) - 1:
                    _rotate_key()
                    continue
                raise
        if description:
            pool = app.state.pool
            async with pool.acquire() as conn:
                existing = await conn.fetchrow("SELECT wiki_about_me FROM users WHERE id = $1", uid)
                current = (existing["wiki_about_me"] or "") if existing else ""
                # Replace any prior appearance assessment block
                lines = [l for l in current.split("\n")
                         if not any(k in l.lower() for k in ("score:", "strengths:", "improve:", "best feature:", "impression:"))]
                appearance_block = f"## Appearance Assessment\n{description}"
                updated = (appearance_block + "\n\n" + "\n".join(lines)).strip()
                await conn.execute("UPDATE users SET wiki_about_me = $1 WHERE id = $2", updated, uid)
    except Exception as e:
        logger.warning(f"analyze-photos failed: {e}")
    return {"success": True}

# ── Device token endpoint (FCM registration) ──────────────────────────────────

class DeviceTokenBody(BaseModel):
    token: str

@app.post("/device-token")
async def save_device_token(body: DeviceTokenBody, uid: str = Depends(verify_token)):
    """Save the device's FCM token so the backend can send push notifications."""
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute("UPDATE users SET fcm_token = $1 WHERE id = $2", body.token, uid)
    logger.info(f"FCM token registered for {uid}")
    return {"success": True}

# ── Direct Messaging Endpoints ─────────────────────────────────────────────────

class MessageBody(BaseModel):
    target_user_id: str
    text: str

@app.post("/messages")
async def send_direct_message(body: MessageBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        await conn.execute(
            "INSERT INTO messages (from_user_id, to_user_id, text) VALUES ($1, $2, $3)",
            uid, body.target_user_id, body.text,
        )
        me = await conn.fetchrow("SELECT display_name FROM users WHERE id = $1", uid)
        my_name = (me["display_name"] if me and me["display_name"] else "Someone")
        notif_body = f"{my_name} sent you a message."
        meta = json.dumps({"from_user_id": uid})
        await conn.execute("""
            INSERT INTO notifications (user_id, type, title, body, meta, read)
            VALUES ($1, 'agent_update', 'New message', $2, $3, FALSE)
        """, body.target_user_id, notif_body, meta)
        recipient_token = await _get_fcm_token(body.target_user_id, conn)

    asyncio.create_task(_send_push(
        recipient_token, f"Message from {my_name}",
        body.text[:PUSH_PREVIEW_LEN], {"from_user_id": uid, "type": "dm"},
    ))
    return {"success": True}

@app.get("/messages/{other_user_id}")
async def get_messages(other_user_id: str, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT id, from_user_id, to_user_id, text, read, created_at 
            FROM messages
            WHERE (from_user_id = $1 AND to_user_id = $2) OR (from_user_id = $2 AND to_user_id = $1)
            ORDER BY created_at ASC
            LIMIT {MESSAGES_LIMIT}
        """, uid, other_user_id)
        
        msgs = []
        for r in rows:
            m = dict(r)
            m["created_at"] = m["created_at"].isoformat()
            m["id"] = str(m["id"])
            msgs.append(m)
        return msgs

# ── Text Chat Endpoint ─────────────────────────────────────────────────────────

class TextChatRequest(BaseModel):
    messages: list[dict]  # [{"role": "user"|"model", "text": "..."}]

@app.post("/chat/text")
@limiter.limit(RATE_CHAT_TEXT)
async def text_chat(request: Request, body: TextChatRequest, uid: str = Depends(verify_token)):
    """Text-mode chat with Ayma — uses same system prompt as voice bootstrap.
    Useful for testing conversation quality without Gemini Live WebSocket."""
    pool = app.state.pool
    async with pool.acquire() as conn:
        profile_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
        if not profile_row:
            raise HTTPException(status_code=404, detail="User not found")
        profile = _parse_row(profile_row)
        active_questions = _active_questions_for_profile(profile)
        answered_keys = _answered_question_keys_from_profile(profile)
        skills_rows = await conn.fetch(
            "SELECT name, content FROM user_skills WHERE user_id = $1 AND enabled = TRUE", uid
        )
        skills = [dict(r) for r in skills_rows]
        questions_rows = await conn.fetch("""
            SELECT key, text, category, sort_order as "order", is_followup
            FROM user_questions
            WHERE user_id = $1 AND answered = FALSE
            ORDER BY CASE category WHEN 'required' THEN 0 WHEN 'deeper' THEN 1 WHEN 'matching_prefs' THEN 2 ELSE 3 END, sort_order
        """, uid)
        pending_questions = [dict(r) for r in questions_rows]

    system_prompt = _build_system_prompt(profile, skills, pending_questions)

    history = []
    for m in body.messages[:-1]:
        role = "user" if m["role"] == "user" else "model"
        history.append({"role": role, "parts": [{"text": m["text"]}]})

    last_msg = body.messages[-1]

    for attempt in range(len(_API_KEYS)):
        try:
            model = genai.GenerativeModel(TEXT_MODEL, system_instruction=system_prompt)
            chat = model.start_chat(history=history)
            resp = await chat.send_message_async(last_msg["text"])
            return {"role": "model", "text": resp.text}
        except Exception as e:
            if _is_quota_error(e) and attempt < len(_API_KEYS) - 1:
                _rotate_key()
                continue
            raise HTTPException(status_code=500, detail=str(e))

# ── Matching & Simulation Engine Helpers ──────────────────────────────────────────

_PII_FIELDS = frozenset({
    "display_name", "location_region", "employer", "email", "phone",
    "location_text", "location_lat", "location_lng",
})

_PROFILE_SKIP = frozenset({
    "id", "onboarding_complete", "matching_paused", "created_at", "updated_at",
    "voice_preference", "voice_accent", "voice_settings", "voice_preferences_updated_at",
    "agent_name", "matching_embedding", "profile_answers_public", 
    "profile_answers_private", "profile_answers_sensitive", "profile_field_visibility",
    "photo_order", "raw_user_statements", "preboarding_seen"
})

def strip_pii(profile: dict) -> dict:
    """Remove personally identifying fields before sending a profile to the scoring LLM."""
    return {k: v for k, v in profile.items() if k not in _PII_FIELDS}

async def _gemini_call(model_name: str, prompt, *, system_instruction=None,
                       generation_config=None) -> str:
    """
    Call Gemini with automatic key rotation on quota exhaustion.
    Tries the primary key, and if it gets a 429/quota error, rotates to the
    backup key and retries once. Returns the response text.
    """
    attempts = len(_API_KEYS)  # try each key at most once
    for attempt in range(attempts):
        try:
            kwargs = {}
            if system_instruction:
                kwargs["system_instruction"] = system_instruction
            model = genai.GenerativeModel(model_name, **kwargs)
            gen_cfg = generation_config or {}
            resp = await model.generate_content_async(prompt, generation_config=gen_cfg)
            return resp.text
        except Exception as e:
            if _is_quota_error(e) and attempt < attempts - 1:
                _rotate_key()
                continue
            raise

def _fmt_profile(profile: dict) -> str:
    skip = _PII_FIELDS | _PROFILE_SKIP
    lines = []
    for k, v in profile.items():
        if k in skip or not v:
            continue
        if isinstance(v, dict):
            lines.append(f"{k}: {json.dumps(v, ensure_ascii=False)}")
        else:
            lines.append(f"{k}: {v}")
    return "\n".join(lines) or "(no profile data)"

MATCHING_SCORING_PROMPT = """You are evaluating compatibility between two people for a matchmaking app.

Person A:
{profile_a}

Person B:
{profile_b}

Assess compatibility based on shared values, lifestyle, relationship goals, personality fit, and complementary qualities.

Return ONLY a JSON object with these exact fields:
{{
  "score": <float 0.0-1.0, where 1.0 is exceptional compatibility>,
  "rationale": "<2-3 sentences explaining overall compatibility>",
  "summary_a": "<1 sentence from Person A's perspective: why Person B is a good match for them>",
  "summary_b": "<1 sentence from Person B's perspective: why Person A is a good match for them>"
}}"""

VIBE_SIM_PROMPT = """You are simulating a first-date conversation between two people to assess their chemistry.

Person A profile:
{profile_a}

Person B profile:
{profile_b}

Generate exactly 5 dialogue turns (Person A starts, they alternate). Each response should be 1-3 sentences. Be authentic to each person's personality, values, and communication style. Make the conversation feel real and spontaneous.

Format your response exactly like this (no other text):
A: [Person A's opening message]
B: [Person B's reply]
A: [Person A's response]
B: [Person B's reply]
A: [Person A's closing message]"""

VIBE_SCORE_PROMPT = """Rate the chemistry and compatibility between Person A and Person B based on their profiles and conversation.

Person A profile:
{profile_a}

Person B profile:
{profile_b}

Their simulated first-date conversation:
{conversation}

Consider: natural rapport, shared interests, complementary values, conversational energy, emotional connection.

Return JSON only: {{"synergyScore": <integer 0-100>, "synergySummary": "<one concise sentence describing their chemistry>"}}"""

async def _generate_embedding(text: str) -> list[float] | None:
    if not text.strip():
        return None
    for attempt in range(len(_API_KEYS)):
        try:
            return await asyncio.to_thread(_embed_text_with_gemini_v2, text)
        except Exception as e:
            if _is_quota_error(e) and attempt < len(_API_KEYS) - 1:
                _rotate_key()
                continue
            logger.warning(f"[embedding] generation failed: {e}")
            return None


def _embed_text_with_gemini_v2(text: str) -> list[float] | None:
    prepared_text = f"{_EMBEDDING_TASK_PREFIX}{text.strip()}"
    result = _embedding_client.models.embed_content(
        model=EMBEDDING_MODEL,
        contents=prepared_text,
        config=google_genai_types.EmbedContentConfig(
            output_dimensionality=_EMBEDDING_OUTPUT_DIMENSIONALITY,
        ),
    )
    embeddings = getattr(result, "embeddings", None) or []
    if not embeddings:
        return None
    values = getattr(embeddings[0], "values", None)
    if values is None and isinstance(embeddings[0], dict):
        values = embeddings[0].get("values")
    if values is None:
        return None
    return list(values)

def _interested_in(prefs: dict, target_gender: str) -> bool:
    pref = (prefs.get("interested_in") or "").lower().strip()
    if not pref or pref == "everyone":
        return True
    g = target_gender.lower().strip()
    if pref in ("men", "man", "male"):
        return g in ("men", "man", "male")
    if pref in ("women", "woman", "female"):
        return g in ("women", "woman", "female")
    return True

def _is_heuristic_match(me: dict, other: dict) -> bool:
    """
    Three-gate hard filter driven by questionnaire_graph.py.

    Gate 1 — Gender/interest  (global, always checked)
    Gate 2 — Age range        (global, always checked)
    Gate 3 — Intent-specific  (only when both share the same intent type)

    Returns True only if the pair clears all three gates.
    """
    my_prefs    = _parse_json_field(me.get("matching_prefs"))
    other_prefs = _parse_json_field(other.get("matching_prefs"))

    # ── Gate 1: gender / interest ──────────────────────────────────────────
    my_gender    = (me.get("gender")    or "").lower().strip()
    other_gender = (other.get("gender") or "").lower().strip()
    if not _interested_in(my_prefs, other_gender):
        return False
    if not _interested_in(other_prefs, my_gender):
        return False

    # ── Gate 2: age range ──────────────────────────────────────────────────
    my_age    = me.get("age")
    other_age = other.get("age")
    if my_age is None or other_age is None:
        return False
    my_min, my_max       = my_prefs.get("age_min"), my_prefs.get("age_max")
    other_min, other_max = other_prefs.get("age_min"), other_prefs.get("age_max")
    if my_min    is not None and other_age < int(my_min):    return False
    if my_max    is not None and other_age > int(my_max):    return False
    if other_min is not None and my_age    < int(other_min): return False
    if other_max is not None and my_age    > int(other_max): return False

    # ── Gate 3: intent-specific hard filters (questionnaire_graph) ─────────
    my_intent    = (my_prefs.get("intent_type")    or "long_term").lower()
    other_intent = (other_prefs.get("intent_type") or "long_term").lower()
    if my_intent != other_intent:
        # Different intents are never matched (e.g. nikah ↔ casual = hard no).
        return False

    extra_filters = get_hard_filters(my_intent)  # global already handled above
    for field in extra_filters:
        if field in ("gender_identity", "interested_in", "age", "location_radius_km"):
            continue  # already checked in gates 1-2
        mv = my_prefs.get(field)
        ov = other_prefs.get(field)
        if mv is None or ov is None:
            continue  # missing data → don't hard-reject; let LLM handle
        if field == "children_intent":
            # "childfree" ↔ "wants_children" is a hard dealbreaker
            childfree = {"childfree", "no", "never"}
            if (str(mv).lower() in childfree) != (str(ov).lower() in childfree):
                return False
        elif field == "polygyny_stance":
            # seeker must match with seeker or open; mono must match mono
            seekers = {"seeking", "open"}
            if (str(mv).lower() in seekers) != (str(ov).lower() in seekers):
                return False
        elif field == "religion":
            if str(mv).lower() != str(ov).lower():
                return False
        elif field in ("dietary_halal", "riba_free_finance"):
            # Boolean: True requirement can't match False
            if bool(mv) != bool(ov):
                return False

    return True

async def _score_pair(
    _model_unused, me: dict, other: dict
) -> dict | None:
    """Call Gemini to score a candidate pair. Returns scoring dict or None on failure."""
    prompt = MATCHING_SCORING_PROMPT.format(
        profile_a=_fmt_profile(strip_pii(me)),
        profile_b=_fmt_profile(strip_pii(other)),
    )
    try:
        raw = await _gemini_call(
            TEXT_MODEL, prompt,
            generation_config={"response_mime_type": "application/json"},
        )
        result = json.loads(raw)
        if not isinstance(result.get("score"), (int, float)):
            return None
        return result
    except Exception:
        return None

async def _run_vibe_check(match_id: int, uid_a: str, uid_b: str, conn, _model_unused) -> dict:
    """Simulate a 5-turn first-date conversation and return synergy score + summary."""
    profile_a_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid_a)
    profile_b_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid_b)

    profile_a = _parse_row(profile_a_row)
    profile_b = _parse_row(profile_b_row)

    fmt_a = _fmt_profile(strip_pii(profile_a))
    fmt_b = _fmt_profile(strip_pii(profile_b))

    # Simulate first-date conversation in 1 LLM call
    sim_prompt = VIBE_SIM_PROMPT.format(profile_a=fmt_a, profile_b=fmt_b)
    try:
        conversation = (await _gemini_call(TEXT_MODEL, sim_prompt)).strip()
    except Exception:
        conversation = "(simulation unavailable)"

    # Rate chemistry and compatibility
    score_prompt = VIBE_SCORE_PROMPT.format(
        profile_a=fmt_a,
        profile_b=fmt_b,
        conversation=conversation,
    )
    try:
        raw = await _gemini_call(
            TEXT_MODEL, score_prompt,
            generation_config={"response_mime_type": "application/json"},
        )
        result = json.loads(raw)
        synergy_score = int(result.get("synergyScore", 50))
        synergy_summary = str(result.get("synergySummary", ""))
    except Exception:
        synergy_score = 50
        synergy_summary = ""
        
    # Parse dialogue and write to match_simulations table
    await conn.execute("DELETE FROM match_simulations WHERE match_id = $1", match_id)
    
    lines = conversation.split('\n')
    turn_idx = 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Map sender uid
        if line.startswith('A:') or line.startswith('Person A:'):
            parts = line.split(':', 1)
            if len(parts) > 1:
                text = parts[1].strip()
                await conn.execute("""
                    INSERT INTO match_simulations (match_id, sender_uid, turn_index, message_text)
                    VALUES ($1, $2, $3, $4)
                """, match_id, uid_a, turn_idx, text)
                turn_idx += 1
        elif line.startswith('B:') or line.startswith('Person B:'):
            parts = line.split(':', 1)
            if len(parts) > 1:
                text = parts[1].strip()
                await conn.execute("""
                    INSERT INTO match_simulations (match_id, sender_uid, turn_index, message_text)
                    VALUES ($1, $2, $3, $4)
                """, match_id, uid_b, turn_idx, text)
                turn_idx += 1
            
    return {
        "synergy_score": max(0, min(100, synergy_score)),
        "synergy_summary": synergy_summary
    }

# ── Matching & Simulation Endpoints ──────────────────────────────────────────────

@app.post("/run-matching")
@limiter.limit(RATE_RUN_MATCHING)
async def run_matching(request: Request, uid: str = Depends(verify_token)):
    pool = app.state.pool
    model = None  # _score_pair and _run_vibe_check now use _gemini_call internally
    
    async with pool.acquire() as conn:
        me_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
        if not me_row:
            raise HTTPException(status_code=404, detail="Profile not found")
        me = _parse_row(me_row)
        
        embedding_vector = None
        if me.get("matching_embedding"):
            try:
                if isinstance(me["matching_embedding"], str):
                    emb_str = me["matching_embedding"].strip("[]")
                    embedding_vector = [float(x) for x in emb_str.split(",") if x.strip()]
                else:
                    embedding_vector = list(me["matching_embedding"])
            except Exception:
                embedding_vector = None
                
        if not embedding_vector:
            pref_text = f"{me.get('wiki_preferences') or ''}\n{me.get('wiki_matching') or ''}".strip()
            if pref_text:
                embedding_vector = await _generate_embedding(pref_text)
                if embedding_vector:
                    vector_str = f"[{','.join(map(str, embedding_vector))}]"
                    await conn.execute("UPDATE users SET matching_embedding = $1::vector WHERE id = $2", vector_str, uid)
                    
        if embedding_vector:
            vector_str = f"[{','.join(map(str, embedding_vector))}]"
            candidate_rows = await conn.fetch(f"""
                SELECT * FROM users
                WHERE onboarding_complete = TRUE
                  AND matching_paused = FALSE
                  AND id != $1
                  AND id NOT IN (
                      SELECT user_a FROM matches WHERE user_b = $1
                      UNION
                      SELECT user_b FROM matches WHERE user_a = $1
                  )
                ORDER BY (CASE WHEN matching_embedding IS NULL THEN 1 ELSE 0 END), matching_embedding <=> $2::vector ASC
                LIMIT {MATCH_CANDIDATE_POOL}
            """, uid, vector_str)
        else:
            candidate_rows = await conn.fetch(f"""
                SELECT * FROM users
                WHERE onboarding_complete = TRUE
                  AND matching_paused = FALSE
                  AND id != $1
                  AND id NOT IN (
                      SELECT user_a FROM matches WHERE user_b = $1
                      UNION
                      SELECT user_b FROM matches WHERE user_a = $1
                  )
                LIMIT {MATCH_CANDIDATE_POOL}
            """, uid)

        candidates = [_parse_row(r) for r in candidate_rows]
        filtered = [c for c in candidates if _is_heuristic_match(me, c)]

        to_score = filtered[:MATCH_SCORE_TOP_K]
        if not to_score:
            return {"matches_created": 0, "candidates_evaluated": 0}
            
        scorings = await asyncio.gather(*[_score_pair(model, me, c) for c in to_score])
        
        scored_pairs = [
            (c, s) for c, s in zip(to_score, scorings)
            if s is not None and float(s.get("score", 0.0)) >= MATCH_SCORE_MIN
        ]
        scored_pairs.sort(key=lambda x: float(x[1].get("score", 0.0)), reverse=True)
        
        created = 0
        vibe_candidates = [p for p in scored_pairs if float(p[1].get("score", 0.0)) >= VIBE_CHECK_THRESHOLD][:VIBE_CHECK_TOP_K]
        vibe_uids = {c["id"] for c, _ in vibe_candidates}
        
        for candidate, scoring in scored_pairs:
            score = round(float(scoring.get("score", 0.0)), 3)
            cuid = candidate["id"]
            
            user_a, user_b = (uid, cuid) if uid < cuid else (cuid, uid)
            if uid < cuid:
                db_summary_a = scoring.get("summary_a", "")
                db_summary_b = scoring.get("summary_b", "")
            else:
                db_summary_a = scoring.get("summary_b", "")
                db_summary_b = scoring.get("summary_a", "")
                
            if cuid in vibe_uids:
                match_id = await conn.fetchval("""
                    INSERT INTO matches (user_a, user_b, score, rationale, summary_a, summary_b, status)
                    VALUES ($1, $2, $3, $4, $5, $6, 'pending')
                    ON CONFLICT (user_a, user_b) DO UPDATE SET 
                        score = EXCLUDED.score, 
                        rationale = EXCLUDED.rationale, 
                        summary_a = EXCLUDED.summary_a, 
                        summary_b = EXCLUDED.summary_b,
                        updated_at = NOW()
                    RETURNING id
                """, user_a, user_b, score, scoring.get("rationale", ""), db_summary_a, db_summary_b)
                
                vibe = await _run_vibe_check(match_id, uid, cuid, conn, model)
                synergy_score = vibe["synergy_score"]
                synergy_summary = vibe["synergy_summary"]
                
                final_score = round(score * FINAL_SCORE_COMPAT_WEIGHT + (synergy_score / 100) * (1 - FINAL_SCORE_COMPAT_WEIGHT), 3)
                
                await conn.execute("""
                    UPDATE matches SET
                        score = $1,
                        synergy_score = $2,
                        synergy_summary = $3,
                        status = 'vibe_checked',
                        updated_at = NOW()
                    WHERE id = $4
                """, final_score, synergy_score, synergy_summary, match_id)
            else:
                await conn.execute("""
                    INSERT INTO matches (user_a, user_b, score, rationale, summary_a, summary_b, status, synergy_score, synergy_summary)
                    VALUES ($1, $2, $3, $4, $5, $6, 'pending', NULL, NULL)
                    ON CONFLICT (user_a, user_b) DO UPDATE SET
                        score = EXCLUDED.score,
                        rationale = EXCLUDED.rationale,
                        summary_a = EXCLUDED.summary_a,
                        summary_b = EXCLUDED.summary_b,
                        status = 'pending',
                        synergy_score = NULL,
                        synergy_summary = NULL,
                        updated_at = NOW()
                """, user_a, user_b, score, scoring.get("rationale", ""), db_summary_a, db_summary_b)
                
            created += 1
            # Push notification: tell the other user they have a new match
            other_token = await _get_fcm_token(cuid, conn)
            me_row = await conn.fetchrow("SELECT display_name FROM users WHERE id = $1", uid)
            my_name = (me_row["display_name"] if me_row and me_row["display_name"] else "Someone")
            asyncio.create_task(_send_push(
                other_token, "New match ✨",
                f"You matched with {my_name}!",
                {"type": "new_match", "match_user_id": uid},
            ))

        logger.info(f"[matching] {uid}: {created} matches created from {len(to_score)} candidates")
        return {"matches_created": created, "candidates_evaluated": len(to_score)}

# ── Cron-triggered matching (Cloud Scheduler) ──────────────────────────────────

@app.post("/run-matching-cron")
async def run_matching_cron(x_cron_secret: str | None = Header(None, alias="X-Cron-Secret")):
    """Cloud Scheduler calls this with X-Cron-Secret header to match all active users.
    Set CRON_SECRET env var in Cloud Run and in the scheduler job HTTP headers."""
    if not CRON_SECRET or x_cron_secret != CRON_SECRET:
        raise HTTPException(status_code=403, detail="Forbidden")
    pool = app.state.pool
    total_created = 0
    async with pool.acquire() as conn:
        user_rows = await conn.fetch(
            "SELECT id FROM users WHERE onboarding_complete = TRUE AND matching_paused = FALSE"
        )
        user_ids = [r["id"] for r in user_rows]
    logger.info(f"[cron] Running matching for {len(user_ids)} users")
    for uid in user_ids:
        try:
            async with pool.acquire() as conn:
                me_row = await conn.fetchrow("SELECT * FROM users WHERE id = $1", uid)
                if not me_row:
                    continue
                me = _parse_row(me_row)
                candidate_rows = await conn.fetch(f"""
                    SELECT * FROM users
                    WHERE onboarding_complete = TRUE AND matching_paused = FALSE AND id != $1
                    AND id NOT IN (
                        SELECT user_a FROM matches WHERE user_b = $1
                        UNION SELECT user_b FROM matches WHERE user_a = $1
                    ) LIMIT {CRON_CANDIDATE_POOL}
                """, uid)
                candidates = [_parse_row(r) for r in candidate_rows]
                filtered = [c for c in candidates if _is_heuristic_match(me, c)][:CRON_SCORE_TOP_K]
                if not filtered:
                    continue
                scorings = await asyncio.gather(*[_score_pair(None, me, c) for c in filtered])
                for candidate, scoring in zip(filtered, scorings):
                    if not scoring or float(scoring.get("score", 0)) < MATCH_SCORE_MIN:
                        continue
                    cuid = candidate["id"]
                    ua, ub = (uid, cuid) if uid < cuid else (cuid, uid)
                    sa = scoring.get("summary_a" if uid < cuid else "summary_b", "")
                    sb = scoring.get("summary_b" if uid < cuid else "summary_a", "")
                    await conn.execute("""
                        INSERT INTO matches (user_a, user_b, score, rationale, summary_a, summary_b, status)
                        VALUES ($1,$2,$3,$4,$5,$6,'pending')
                        ON CONFLICT (user_a, user_b) DO NOTHING
                    """, ua, ub, round(float(scoring.get("score", 0)), 3),
                        scoring.get("rationale", ""), sa, sb)
                    total_created += 1
        except Exception as e:
            logger.warning(f"[cron] matching failed for {uid}: {e}")
    logger.info(f"[cron] Matching complete: {total_created} new matches")
    return {"total_matches_created": total_created, "users_processed": len(user_ids)}

class VibeCheckRequest(BaseModel):
    match_id: int

@app.post("/vibe-check")
async def vibe_check(body: VibeCheckRequest, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        match_row = await conn.fetchrow("SELECT * FROM matches WHERE id = $1", body.match_id)
        if not match_row:
            raise HTTPException(status_code=404, detail="Match not found")

        match = dict(match_row)
        uid_a = match.get("user_a")
        uid_b = match.get("user_b")

        if uid not in (uid_a, uid_b):
            raise HTTPException(status_code=403, detail="Not your match")

        other_uid = uid_b if uid == uid_a else uid_a
        result = await _run_vibe_check(body.match_id, uid, other_uid, conn, None)
        synergy_score = result["synergy_score"]
        synergy_summary = result["synergy_summary"]
        
        compat_score = float(match.get("score") or 0.0)
        final_score = round(compat_score * FINAL_SCORE_COMPAT_WEIGHT + (synergy_score / 100) * (1 - FINAL_SCORE_COMPAT_WEIGHT), 3)
        
        await conn.execute("""
            UPDATE matches SET
                score = $1,
                synergy_score = $2,
                synergy_summary = $3,
                status = 'vibe_checked',
                updated_at = NOW()
            WHERE id = $4
        """, final_score, synergy_score, synergy_summary, body.match_id)
        
        return {
            "synergy_score": synergy_score,
            "synergy_summary": synergy_summary
        }

@app.get("/matches/{match_id}/simulation")
async def get_match_simulation(match_id: int, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        match_row = await conn.fetchrow("SELECT user_a, user_b, show_simulation_transcript FROM matches WHERE id = $1", match_id)
        if not match_row:
            raise HTTPException(status_code=404, detail="Match not found")
            
        match = dict(match_row)
        if uid not in (match["user_a"], match["user_b"]):
            raise HTTPException(status_code=403, detail="Not authorized to view this match simulation")
            
        if not match["show_simulation_transcript"]:
            return []
            
        rows = await conn.fetch("""
            SELECT sender_uid, turn_index, message_text, created_at 
            FROM match_simulations 
            WHERE match_id = $1 
            ORDER BY turn_index ASC
        """, match_id)
        
        res = []
        for r in rows:
            d = dict(r)
            d["created_at"] = d["created_at"].isoformat()
            res.append(d)
        return res

class ToggleSimulationBody(BaseModel):
    show_simulation_transcript: bool

@app.post("/matches/{match_id}/toggle-simulation")
async def toggle_match_simulation(match_id: int, body: ToggleSimulationBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        match_row = await conn.fetchrow("SELECT user_a, user_b FROM matches WHERE id = $1", match_id)
        if not match_row:
            raise HTTPException(status_code=404, detail="Match not found")
        match = dict(match_row)
        if uid not in (match["user_a"], match["user_b"]):
            raise HTTPException(status_code=403, detail="Not authorized")
            
        await conn.execute("""
            UPDATE matches 
            SET show_simulation_transcript = $1, updated_at = NOW() 
            WHERE id = $2
        """, body.show_simulation_transcript, match_id)
        
    return {"success": True}
