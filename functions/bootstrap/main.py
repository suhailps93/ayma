"""
Ayma Bootstrap — Cloud Run function backed by Firestore.

Endpoints:
  POST /bootstrap      — verify Firebase ID token, build system prompt, return Gemini Live creds
  POST /post-turn      — upsert LLM wiki + mark questions answered
  POST /run-matching   — heuristic filter → PII-stripped Gemini scoring → write matches
  GET  /profile        — fetch self profile
  POST /profile        — update self profile
  GET  /profile/{userId}/public — fetch public profile of a match candidate
  GET  /insights       — fetch memory wiki blocks + media
  GET  /matches        — fetch matches
  POST /matches/{pair_id}/status — accept/reject a match
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
import math
import os
import re
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

import firebase_admin
import google.generativeai as genai
from google import genai as google_genai
from google.api_core.exceptions import AlreadyExists
from google.cloud import firestore
from google.cloud.firestore import AsyncClient
from google.cloud.firestore_v1.base_query import FieldFilter
from google.cloud.firestore_v1.vector import Vector
from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
from google.genai import types as google_genai_types
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth, app_check, messaging
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
    GOOGLE_API_KEY,
    LIVE_MODEL,
    TEXT_MODEL,
    EMBEDDING_MODEL,
    ADMIN_PASSWORD,
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
    APP_CHECK_ENFORCE,
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

    Firestore backs the app data layer. Launches LiveKit agent server as a background
    task so FastAPI binds to PORT 8080 immediately.
    """
    app.state.db = AsyncClient(project=FIREBASE_PROJECT_ID)
    agent_task: asyncio.Task | None = None
    try:
        # Import lazily after main.py has finished defining the Firestore helper
        # functions that agent.py imports. A module-level import creates a
        # circular import and silently prevents the LiveKit worker from starting.
        from agent import start_agent_server

        agent_task = await start_agent_server()
        if agent_task is None:
            logger.warning("LiveKit AgentServer did not start.")
        else:
            logger.info("LiveKit AgentServer task scheduled.")

            def _log_agent_done(task: asyncio.Task) -> None:
                if task.cancelled():
                    return
                exc = task.exception()
                if exc is not None:
                    logger.error(f"LiveKit AgentServer task exited: {exc}")

            agent_task.add_done_callback(_log_agent_done)
    except Exception as e:
        logger.exception(f"LiveKit AgentServer failed to start: {e}")

    yield

    # Shutdown Agent Server
    if agent_task:
        agent_task.cancel()
        try:
            await agent_task
        except asyncio.CancelledError:
            pass

    if getattr(app.state, "db", None) is not None:
        try:
            await app.state.db.close()
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

security = HTTPBearer()

# ── Auth ──────────────────────────────────────────────────────────────────────

def _verify_app_check_token(request: Request) -> None:
    token = request.headers.get("X-Firebase-AppCheck")
    if not token:
        if APP_CHECK_ENFORCE:
            raise HTTPException(status_code=401, detail="Missing App Check token")
        logger.warning("App Check token missing (monitor mode)")
        return
    try:
        app_check.verify_token(token)
    except Exception as exc:
        if APP_CHECK_ENFORCE:
            raise HTTPException(status_code=401, detail="Invalid App Check token")
        logger.warning(f"App Check verification failed (monitor mode): {exc}")


def verify_token(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> str:
    _verify_app_check_token(request)
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

# ── Firestore users/{uid} helpers (Step 3a migration) ─────────────────────────
# 1:1 field mapping of the `users` SQL table (schema.sql), minus the dead
# `matching_embedding` column (Step 2 removed its only caller). JSONB columns
# map to native Firestore maps/lists; TIMESTAMP columns use SERVER_TIMESTAMP.

_USER_DOC_DEFAULTS: dict = {
    "display_name": None,
    "profile_public": "",
    "profile_private": "",
    "profile_ai_observations": "",
    "agent_name": "Ayma",
    "voice_preference": "Charon",
    "matching_prefs": {},
    "age": None,
    "gender": None,
    "location_region": None,
    "location_coords": {},
    "onboarding_complete": False,
    "matching_paused": False,
    "preboarding_seen": False,
    "photo_order": [],
    "voice_settings": {},
    "profile_public_locked": False,
    "community_profile": "dating_standard",
    "profile_public_user_edited": False,
    "profile_public_pending": "",
    "wiki_about_me": "",
    "wiki_context": "",
    "wiki_preferences": "",
    "wiki_matching": "",
    "wiki_profile_structured": "",
    "profile_answers": {},
    "profile_answers_public": {},
    "profile_answers_private": {},
    "profile_answers_sensitive": {},
    "profile_field_visibility": {},
    "raw_user_statements": [],
    "explore_attrs": {},
    "fcm_token": None,
}


def _user_doc_ref(db, uid):
    return db.collection("users").document(uid)


def parse_user_doc(snapshot) -> dict:
    """Mirrors `_parse_row`'s role, but for a Firestore users/{uid} document."""
    if not snapshot or not snapshot.exists:
        return {}

    res = snapshot.to_dict() or {}
    res["id"] = snapshot.id

    for key, default_value in _USER_DOC_DEFAULTS.items():
        if key not in res:
            if isinstance(default_value, dict):
                res[key] = dict(default_value)
            elif isinstance(default_value, list):
                res[key] = list(default_value)
            else:
                res[key] = default_value

    for key, value in list(res.items()):
        if isinstance(value, datetime):
            res[key] = _serialize_value(value)

    return res


async def get_user_doc(db, uid: str) -> dict:
    snapshot = await _user_doc_ref(db, uid).get()
    return parse_user_doc(snapshot)


async def ensure_user_doc(db, uid: str, display_name: str = "User") -> dict:
    """Idempotent create-if-missing, mirrors `INSERT ... ON CONFLICT DO NOTHING`."""
    ref = _user_doc_ref(db, uid)
    snapshot = await ref.get()
    if snapshot.exists:
        return parse_user_doc(snapshot)

    payload = {
        **_USER_DOC_DEFAULTS,
        "id": uid,
        "display_name": display_name,
        "created_at": firestore.SERVER_TIMESTAMP,
        "updated_at": firestore.SERVER_TIMESTAMP,
    }

    try:
        await ref.create(payload)
    except AlreadyExists:
        pass

    return await get_user_doc(db, uid)


async def update_user_doc(db, uid: str, fields: dict) -> None:
    await _user_doc_ref(db, uid).set(
        {
            **fields,
            "updated_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

# ── Firestore matches/{pairId} helpers (Step 3b migration) ───────────────────
# pairId = "_".join(sorted([uid_a, uid_b])) — deterministic ID replacing the
# Postgres `UNIQUE (user_a, user_b)` constraint + `ON CONFLICT DO UPDATE` upsert.
# `match_simulations` becomes the `matches/{pairId}/simulations` subcollection.

_MATCH_DOC_DEFAULTS: dict = {
    "user_a": None,
    "user_b": None,
    "score": None,
    "rationale": "",
    "summary_a": "",
    "summary_b": "",
    "synergy_score": None,
    "synergy_summary": "",
    "status": "pending",
    "show_simulation_transcript": True,
}


def _pair_id(uid_a: str, uid_b: str) -> str:
    return "_".join(sorted([uid_a, uid_b]))


def _match_doc_ref(db, pid: str):
    return db.collection("matches").document(pid)


def parse_match_doc(snapshot) -> dict:
    """Mirrors `parse_user_doc`'s role, but for a Firestore matches/{pairId} document."""
    if not snapshot or not snapshot.exists:
        return {}

    res = snapshot.to_dict() or {}
    res["id"] = snapshot.id

    for key, default_value in _MATCH_DOC_DEFAULTS.items():
        if key not in res:
            if isinstance(default_value, dict):
                res[key] = dict(default_value)
            elif isinstance(default_value, list):
                res[key] = list(default_value)
            else:
                res[key] = default_value

    for key, value in list(res.items()):
        if isinstance(value, datetime):
            res[key] = _serialize_value(value)

    return res


async def get_match_doc(db, pid: str) -> dict:
    snapshot = await _match_doc_ref(db, pid).get()
    return parse_match_doc(snapshot)


async def upsert_match_doc(db, uid_a: str, uid_b: str, fields: dict) -> str:
    """set(merge=True) on the deterministic pairId doc — the direct equivalent
    of `INSERT ... ON CONFLICT (user_a, user_b) DO UPDATE`."""
    pid = _pair_id(uid_a, uid_b)
    ref = _match_doc_ref(db, pid)
    snapshot = await ref.get()

    payload = {
        **fields,
        "user_a": uid_a,
        "user_b": uid_b,
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    if not snapshot.exists:
        payload["created_at"] = firestore.SERVER_TIMESTAMP
        if "status" not in fields:
            payload["status"] = "pending"

    await ref.set(payload, merge=True)
    return pid


async def get_matches_for_user(db, uid: str) -> list[dict]:
    """Both directions of the match pair — Firestore has no OR query, so this
    runs two equality queries and merges results."""
    seen: set[str] = set()
    matches: list[dict] = []

    query_a = db.collection("matches").where(filter=FieldFilter("user_a", "==", uid))
    async for snapshot in query_a.stream():
        if snapshot.id in seen:
            continue
        seen.add(snapshot.id)
        matches.append(parse_match_doc(snapshot))

    query_b = db.collection("matches").where(filter=FieldFilter("user_b", "==", uid))
    async for snapshot in query_b.stream():
        if snapshot.id in seen:
            continue
        seen.add(snapshot.id)
        matches.append(parse_match_doc(snapshot))

    return matches


def _match_simulations_ref(db, pid: str):
    return _match_doc_ref(db, pid).collection("simulations")


async def replace_match_simulations(db, pid: str, turns: list[dict]) -> None:
    """Deletes existing simulation turns and writes new ones — mirrors the old
    `DELETE FROM match_simulations WHERE match_id = ...` + per-line INSERT."""
    ref = _match_simulations_ref(db, pid)
    snapshots = [snapshot async for snapshot in ref.stream()]
    for snapshot in snapshots:
        await snapshot.reference.delete()

    for turn in turns:
        await ref.add({
            "sender_uid": turn["sender_uid"],
            "turn_index": turn["turn_index"],
            "message_text": turn["message_text"],
            "created_at": firestore.SERVER_TIMESTAMP,
        })


async def get_match_simulations(db, pid: str) -> list[dict]:
    rows = []
    query = _match_simulations_ref(db, pid).order_by("turn_index")
    async for snapshot in query.stream():
        data = snapshot.to_dict() or {}
        rows.append({
            "sender_uid": data.get("sender_uid"),
            "turn_index": data.get("turn_index"),
            "message_text": data.get("message_text"),
            "created_at": _serialize_value(data.get("created_at")) if data.get("created_at") is not None else None,
        })
    return rows


async def _all_match_counts(db) -> dict[str, int]:
    """Admin-only, low-traffic: a full matches collection scan is acceptable here."""
    counts: dict[str, int] = {}
    query = db.collection("matches").select(["user_a", "user_b"])
    async for snapshot in query.stream():
        data = snapshot.to_dict() or {}
        user_a = data.get("user_a")
        user_b = data.get("user_b")
        if user_a:
            counts[user_a] = counts.get(user_a, 0) + 1
        if user_b:
            counts[user_b] = counts.get(user_b, 0) + 1
    return counts

# ── Firestore conversations/{pairId}/messages helpers (Step 3c migration) ────
# pairId reuses `_pair_id` from the matches helpers above, so a conversation
# shares its parent key with the corresponding match doc.

def _conversation_messages_ref(db, pid: str):
    return db.collection("conversations").document(pid).collection("messages")


def _parse_message_doc(snapshot) -> dict:
    """Mirrors `parse_user_doc`'s role, but for a Firestore
    conversations/{pairId}/messages/{messageId} document."""
    if not snapshot or not snapshot.exists:
        return {}

    data = snapshot.to_dict() or {}
    created_at = data.get("created_at")
    return {
        "id": snapshot.id,
        "from_user_id": data.get("from_user_id"),
        "to_user_id": data.get("to_user_id"),
        "text": data.get("text") or "",
        "read": bool(data.get("read", False)),
        "created_at": _serialize_value(created_at) if created_at is not None else None,
    }


async def send_message(db, from_uid: str, to_uid: str, text: str) -> dict:
    """Writes a conversation message doc — mirrors
    `INSERT INTO messages (from_user_id, to_user_id, text) VALUES (...)`."""
    pid = _pair_id(from_uid, to_uid)
    _, doc_ref = await _conversation_messages_ref(db, pid).add({
        "from_user_id": from_uid,
        "to_user_id": to_uid,
        "text": text,
        "read": False,
        "created_at": firestore.SERVER_TIMESTAMP,
    })
    snapshot = await doc_ref.get()
    return _parse_message_doc(snapshot)


async def get_conversation_messages(db, uid_a: str, uid_b: str, limit: int = MESSAGES_LIMIT) -> list[dict]:
    """Reads one deterministic conversation thread — mirrors the old
    `WHERE (from=a AND to=b) OR (from=b AND to=a) ORDER BY created_at ASC LIMIT ...`."""
    pid = _pair_id(uid_a, uid_b)
    rows = []
    query = _conversation_messages_ref(db, pid).order_by("created_at").limit(limit)
    async for snapshot in query.stream():
        rows.append(_parse_message_doc(snapshot))
    return rows


async def get_all_messages_for_user(db, uid: str) -> list[dict]:
    """Firestore collection-group query across every
    conversations/{pairId}/messages subcollection, analogous to
    `get_matches_for_user`'s two-query merge, used by the admin detail endpoint."""
    seen: set[str] = set()
    messages: list[dict] = []

    try:
        query_from = db.collection_group("messages").where(filter=FieldFilter("from_user_id", "==", uid))
        async for snapshot in query_from.stream():
            if snapshot.id in seen:
                continue
            seen.add(snapshot.id)
            messages.append(_parse_message_doc(snapshot))

        query_to = db.collection_group("messages").where(filter=FieldFilter("to_user_id", "==", uid))
        async for snapshot in query_to.stream():
            if snapshot.id in seen:
                continue
            seen.add(snapshot.id)
            messages.append(_parse_message_doc(snapshot))
    except Exception as e:
        logger.warning(f"Failed to query collection_group messages ({uid}): {e}")

    messages.sort(
        key=lambda m: (m.get("created_at") or "", m.get("id") or ""),
        reverse=True,
    )
    return messages


async def _all_message_counts(db) -> dict[str, int]:
    """Admin-only, low-traffic: mirrors `_all_match_counts`."""
    counts: dict[str, int] = {}
    query = db.collection_group("messages").select(["from_user_id", "to_user_id"])
    async for snapshot in query.stream():
        data = snapshot.to_dict() or {}
        from_user_id = data.get("from_user_id")
        to_user_id = data.get("to_user_id")
        if from_user_id:
            counts[from_user_id] = counts.get(from_user_id, 0) + 1
        if to_user_id:
            counts[to_user_id] = counts.get(to_user_id, 0) + 1
    return counts

# ── Firestore users/{uid} subcollection helpers (Step 3d migration) ──────────

_QUESTION_CATEGORY_ORDER = {
    "required": 0,
    "deeper": 1,
    "matching_prefs": 2,
    "followup": 3,
}


def _user_subcollection_ref(db, uid: str, name: str):
    return _user_doc_ref(db, uid).collection(name)


def _parse_subcollection_doc(snapshot) -> dict:
    data = snapshot.to_dict() or {}
    data["id"] = snapshot.id
    for key, value in list(data.items()):
        if isinstance(value, datetime):
            data[key] = _serialize_value(value)
    return data


async def get_enabled_skills(db, uid: str) -> list[dict]:
    rows = []
    query = _user_subcollection_ref(db, uid, "user_skills").where(
        filter=FieldFilter("enabled", "==", True)
    )
    async for snapshot in query.stream():
        rows.append(_parse_subcollection_doc(snapshot))
    rows.sort(key=lambda row: row.get("skill_id") or row.get("id") or "")
    return rows


async def list_user_questions(db, uid: str) -> list[dict]:
    rows = []
    async for snapshot in _user_subcollection_ref(db, uid, "user_questions").stream():
        row = _parse_subcollection_doc(snapshot)
        row.setdefault("user_id", uid)
        row.setdefault("question_id", snapshot.id)
        row["answered"] = bool(row.get("answered", False))
        row["is_followup"] = bool(row.get("is_followup", False))
        rows.append(row)
    rows.sort(
        key=lambda row: (
            row.get("answered", False),
            row.get("is_followup", False),
            row.get("sort_order", 99),
            row.get("question_id") or row.get("id") or "",
        )
    )
    return rows


async def user_questions_exist(db, uid: str) -> bool:
    query = _user_subcollection_ref(db, uid, "user_questions").limit(1)
    async for _ in query.stream():
        return True
    return False


async def seed_user_questions_if_empty(
    db,
    uid: str,
    active_questions: list[dict],
    answered_keys: set[str],
) -> None:
    if await user_questions_exist(db, uid):
        return

    batch = db.batch()
    now_iso = datetime.now(timezone.utc).isoformat()
    for question in active_questions:
        qid = question.get("id")
        if not qid:
            continue
        answered = qid in answered_keys
        batch.set(
            _user_subcollection_ref(db, uid, "user_questions").document(qid),
            {
                "user_id": uid,
                "question_id": qid,
                "key": qid,
                "text": question.get("question_text", ""),
                "category": _question_category(question),
                "sort_order": 99,
                "answered": answered,
                "answered_at": now_iso if answered else None,
                "is_followup": False,
            },
        )
    await batch.commit()


async def get_pending_user_questions(
    db,
    uid: str,
    *,
    include_followup: bool = True,
) -> list[dict]:
    rows = []
    for row in await list_user_questions(db, uid):
        if row.get("answered"):
            continue
        if not include_followup and row.get("is_followup"):
            continue
        rows.append(
            {
                "question_id": row.get("question_id") or row.get("id"),
                "key": row.get("key"),
                "text": row.get("text"),
                "category": row.get("category"),
                "order": row.get("sort_order", 99),
                "is_followup": bool(row.get("is_followup", False)),
            }
        )
    rows.sort(
        key=lambda row: (
            _QUESTION_CATEGORY_ORDER.get(row.get("category"), 99),
            row.get("order", 99),
            row.get("question_id") or "",
        )
    )
    return rows


async def mark_user_questions_answered_by_keys(db, uid: str, keys: set[str]) -> None:
    if not keys:
        return
    batch = db.batch()
    changed = False
    for row in await list_user_questions(db, uid):
        if row.get("key") not in keys or row.get("answered"):
            continue
        batch.set(
            _user_subcollection_ref(db, uid, "user_questions").document(row["question_id"]),
            {
                "answered": True,
                "answered_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        changed = True
    if changed:
        await batch.commit()


async def add_followup_question_doc(db, uid: str, question_id: str, question_text: str) -> None:
    await _user_subcollection_ref(db, uid, "user_questions").document(question_id).set(
        {
            "user_id": uid,
            "question_id": question_id,
            "key": question_id,
            "text": question_text,
            "category": "followup",
            "sort_order": 1,
            "answered": False,
            "answered_at": None,
            "is_followup": True,
        },
        merge=True,
    )


async def mark_question_answered_doc(db, uid: str, question_id: str) -> None:
    await _user_subcollection_ref(db, uid, "user_questions").document(question_id).set(
        {
            "answered": True,
            "answered_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )


async def add_user_memory(db, uid: str, text: str, session_id: str | None) -> None:
    doc_data = {
        "user_id": uid,
        "text": text,
        "session_id": session_id,
        "created_at": firestore.SERVER_TIMESTAMP,
    }
    try:
        vector_vals = _embed_text_with_gemini_v2(text)
        if vector_vals:
            doc_data["embedding"] = Vector(vector_vals)
    except Exception as e:
        logger.warning(f"Failed to generate embedding for user memory ({uid}): {e}")

    await _user_subcollection_ref(db, uid, "user_memories").add(doc_data)


async def list_user_memories(db, uid: str) -> list[dict]:
    rows = []
    async for snapshot in _user_subcollection_ref(db, uid, "user_memories").stream():
        row = _parse_subcollection_doc(snapshot)
        row.setdefault("user_id", uid)
        rows.append(row)
    rows.sort(key=lambda row: (row.get("created_at") or "", row.get("id") or ""), reverse=True)
    return rows


async def get_relevant_user_memories(
    db, uid: str, query_text: str | None = None, limit: int = 5
) -> list[dict]:
    """
    Retrieves user memories. If query_text is provided, uses Firestore native vector search
    (find_nearest with COSINE distance) to return top-K relevant memories.
    Falls back to recent memory list if query embedding fails or vector index is not available.
    """
    if query_text:
        try:
            query_vals = _embed_text_with_gemini_v2(query_text)
            if query_vals:
                memories_ref = _user_subcollection_ref(db, uid, "user_memories")
                vector_query = memories_ref.find_nearest(
                    vector_field="embedding",
                    query_vector=Vector(query_vals),
                    distance_measure=DistanceMeasure.COSINE,
                    limit=limit,
                )
                rows = []
                async for snapshot in vector_query.stream():
                    row = _parse_subcollection_doc(snapshot)
                    row.setdefault("user_id", uid)
                    rows.append(row)
                if rows:
                    return rows
        except Exception as e:
            logger.warning(
                f"Vector search failed for user memories ({uid}), falling back to recent list: {e}"
            )

    all_memories = await list_user_memories(db, uid)
    return all_memories[:limit]


async def list_user_media(db, uid: str, limit: int | None = None) -> list[dict]:
    rows = []
    async for snapshot in _user_subcollection_ref(db, uid, "user_media").stream():
        row = _parse_subcollection_doc(snapshot)
        row.setdefault("user_id", uid)
        rows.append(row)
    rows.sort(key=lambda row: (row.get("created_at") or "", row.get("id") or ""), reverse=True)
    if limit is not None:
        rows = rows[:limit]
    return rows


async def save_user_media(db, uid: str, photo_url: str, caption: str | None) -> None:
    await _user_subcollection_ref(db, uid, "user_media").add(
        {
            "user_id": uid,
            "photo_url": photo_url,
            "caption": caption,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )


async def delete_user_media_by_url_doc(db, uid: str, photo_url: str) -> None:
    snapshots = [
        snapshot
        async for snapshot in _user_subcollection_ref(db, uid, "user_media")
        .where(filter=FieldFilter("photo_url", "==", photo_url))
        .stream()
    ]
    for snapshot in snapshots:
        await snapshot.reference.delete()


async def create_notification(
    db,
    uid: str,
    notif_type: str,
    title: str,
    body: str,
    meta: dict | None = None,
) -> str:
    _, doc_ref = await _user_subcollection_ref(db, uid, "notifications").add(
        {
            "user_id": uid,
            "type": notif_type,
            "title": title,
            "body": body,
            "meta": meta or {},
            "read": False,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )
    return doc_ref.id


async def get_notifications_for_user(db, uid: str, limit: int = NOTIFICATIONS_LIMIT) -> list[dict]:
    rows = []
    async for snapshot in _user_subcollection_ref(db, uid, "notifications").stream():
        row = _parse_subcollection_doc(snapshot)
        row.setdefault("user_id", uid)
        row["meta"] = row.get("meta") or {}
        row["read"] = bool(row.get("read", False))
        rows.append(row)
    rows.sort(key=lambda row: (row.get("created_at") or "", row.get("id") or ""), reverse=True)
    return rows[:limit]


async def mark_notification_read_doc(db, uid: str, notif_id: str) -> None:
    await _user_subcollection_ref(db, uid, "notifications").document(notif_id).set(
        {
            "read": True,
        },
        merge=True,
    )


async def mark_all_notifications_read_docs(db, uid: str) -> None:
    batch = db.batch()
    changed = False
    async for snapshot in _user_subcollection_ref(db, uid, "notifications").where(
        filter=FieldFilter("read", "==", False)
    ).stream():
        batch.set(snapshot.reference, {"read": True}, merge=True)
        changed = True
    if changed:
        await batch.commit()


async def _all_user_subcollection_counts(db, collection_name: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    query = db.collection_group(collection_name).select(["user_id"])
    async for snapshot in query.stream():
        data = snapshot.to_dict() or {}
        user_id = data.get("user_id")
        if user_id:
            counts[user_id] = counts.get(user_id, 0) + 1
    return counts


async def _all_unread_notification_counts(db) -> dict[str, int]:
    counts: dict[str, int] = {}
    try:
        query = db.collection_group("notifications").where(
            filter=FieldFilter("read", "==", False)
        ).select(["user_id"])
        async for snapshot in query.stream():
            data = snapshot.to_dict() or {}
            user_id = data.get("user_id")
            if user_id:
                counts[user_id] = counts.get(user_id, 0) + 1
    except Exception as e:
        logger.warning(f"Failed to query collection_group notifications: {e}")
    return counts

# ── Bootstrap ─────────────────────────────────────────────────────────────────

@app.post("/bootstrap")
@limiter.limit(RATE_BOOTSTRAP)
async def bootstrap(request: Request, uid: str = Depends(verify_token)):
    db = app.state.db

    profile = await get_user_doc(db, uid)
    if not profile:
        display_name = "User"
        try:
            user_record = auth.get_user(uid)
            if user_record.display_name:
                display_name = user_record.display_name
        except Exception:
            pass
        profile = await ensure_user_doc(db, uid, display_name=display_name)

    active_questions = _active_questions_for_profile(profile)
    answered_keys = _answered_question_keys_from_profile(profile)
    skills = await get_enabled_skills(db, uid)
    await seed_user_questions_if_empty(db, uid, active_questions, answered_keys)
    pending_questions = await get_pending_user_questions(db, uid)

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


async def _process_post_turn_from_messages(
    db,
    *,
    uid: str,
    session_id: str,
    messages: list[dict],
) -> dict[str, bool]:
    if not messages:
        return {"updated": False}

    conversation = "\n".join(
        f"{m['role'].upper()}: {m['text']}" for m in messages[-10:]
    )

    profile = await get_user_doc(db, uid)
    if not profile:
        return {"updated": False}
    active_questions = _active_questions_for_profile(profile)
    user_name = profile.get("display_name") or "User"

    user_lines = [m["text"] for m in messages[-10:] if m.get("role") == "user" and m.get("text", "").strip()]
    raw_user_statements = list(profile.get("raw_user_statements") or [])
    if user_lines:
        raw_user_statements = (raw_user_statements + user_lines)[-100:]
        await update_user_doc(db, uid, {"raw_user_statements": raw_user_statements})

    pending_questions = await get_pending_user_questions(db, uid, include_followup=False)

    field_catalog = "\n".join(
        f"- {q.get('id')}: {q.get('question_text')}"
        for q in active_questions
        if q.get("id")
    )
    unanswered_questions_list = "\n".join(
        f"- {q['key']}: {q['text']}" for q in pending_questions
    )

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

    narrative_answers = payload.get("narrative_answers") or []
    valid_narrative_ids = {p["id"] for p in all_narratives}
    for item in narrative_answers:
        nid = item.get("id")
        answer_text = (item.get("answer") or "").strip()
        if nid and nid in valid_narrative_ids and answer_text:
            existing_answers[nid] = answer_text
            entry = f"\n- [{nid}] {answer_text}"
            if entry not in wiki_matching:
                wiki_matching = (wiki_matching or "") + entry

    structured_wiki = _render_structured_wiki(existing_answers)
    await update_user_doc(
        db,
        uid,
        {
            "wiki_about_me": wiki_about_me,
            "wiki_context": wiki_context,
            "wiki_preferences": wiki_preferences,
            "wiki_matching": wiki_matching,
            "profile_answers": existing_answers,
            "profile_answers_public": public_map,
            "profile_answers_private": private_map,
            "profile_answers_sensitive": sensitive_map,
            "profile_field_visibility": visibility_map,
            "wiki_profile_structured": structured_wiki,
            "profile_ai_observations": extracted_summary or profile.get("profile_ai_observations") or "",
            "profile_public": extracted_summary or profile.get("profile_public") or "",
            "raw_user_statements": raw_user_statements,
            "explore_attrs": _build_explore_attrs(public_map),
        },
    )

    all_answered_keys = answered_keys | set(existing_answers.keys())
    await mark_user_questions_answered_by_keys(db, uid, set(all_answered_keys))
    await add_user_memory(db, uid, conversation, session_id)

    return {"updated": True}

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
    result = await _process_post_turn_from_messages(
        app.state.db,
        uid=uid,
        session_id=body.session_id,
        messages=body.messages,
    )
    return result

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
    db = app.state.db
    safe_limit = max(1, min(limit, 500))
    users = []
    async for snapshot in db.collection("users").stream():
        doc = parse_user_doc(snapshot)
        users.append(
            {
                "id": doc.get("id"),
                "display_name": doc.get("display_name"),
                "age": doc.get("age"),
                "gender": doc.get("gender"),
                "location_region": doc.get("location_region"),
                "community_profile": doc.get("community_profile"),
                "onboarding_complete": doc.get("onboarding_complete"),
                "matching_paused": doc.get("matching_paused"),
                "profile_public": doc.get("profile_public"),
                "updated_at": doc.get("updated_at"),
                "created_at": doc.get("created_at"),
                "intent_type": _parse_json_field(doc.get("matching_prefs")).get("intent_type", ""),
            }
        )

    photo_counts, memory_counts, unread_notification_counts, match_counts, message_counts = await asyncio.gather(
        _all_user_subcollection_counts(db, "user_media"),
        _all_user_subcollection_counts(db, "user_memories"),
        _all_unread_notification_counts(db),
        _all_match_counts(db),
        _all_message_counts(db),
    )

    records = []
    query_lower = (query or "").strip().lower()
    for rec in users:
        haystack = " ".join(
            str(rec.get(field) or "")
            for field in ("id", "display_name", "profile_public", "location_region")
        ).lower()
        rec["photo_count"] = photo_counts.get(rec["id"], 0)
        rec["memory_count"] = memory_counts.get(rec["id"], 0)
        rec["unread_notifications"] = unread_notification_counts.get(rec["id"], 0)
        rec["match_count"] = match_counts.get(rec["id"], 0)
        rec["message_count"] = message_counts.get(rec["id"], 0)

        if query_lower and query_lower not in haystack:
            continue
        if gender and rec.get("gender") != gender:
            continue
        if community_profile and rec.get("community_profile") != community_profile:
            continue
        if intent_type and rec.get("intent_type") != intent_type:
            continue
        if onboarding_complete is not None and rec.get("onboarding_complete") != onboarding_complete:
            continue
        if matching_paused is not None and rec.get("matching_paused") != matching_paused:
            continue
        if min_age is not None and (rec.get("age") is None or rec["age"] < min_age):
            continue
        if max_age is not None and (rec.get("age") is None or rec["age"] > max_age):
            continue
        if has_photos is not None and (rec["photo_count"] > 0) != has_photos:
            continue
        if has_matches is not None and (rec["match_count"] > 0) != has_matches:
            continue
        if has_messages is not None and (rec["message_count"] > 0) != has_messages:
            continue
        records.append(rec)

    records.sort(
        key=lambda rec: (rec.get("updated_at") or "", rec.get("created_at") or "", rec.get("id") or ""),
        reverse=True,
    )
    records = records[:safe_limit]
    for rec in records:
        rec.pop("created_at", None)
    return records


@app.get("/admin/users/{target_uid}")
async def admin_get_user_detail(target_uid: str, admin_ok: bool = Depends(verify_admin)):
    del admin_ok
    db = app.state.db
    user_doc = await get_user_doc(db, target_uid)
    if not user_doc:
        raise HTTPException(status_code=404, detail="User not found")

    skills_rows, questions_rows, memories_rows, media_rows, notifications_rows, match_docs, message_rows = await asyncio.gather(
        get_enabled_skills(db, target_uid),
        list_user_questions(db, target_uid),
        list_user_memories(db, target_uid),
        list_user_media(db, target_uid),
        get_notifications_for_user(db, target_uid, limit=1000),
        get_matches_for_user(db, target_uid),
        get_all_messages_for_user(db, target_uid),
    )
    match_docs.sort(
        key=lambda m: (m.get("updated_at") or "", m.get("created_at") or "", m.get("id") or ""),
        reverse=True,
    )

    serialized_matches = []
    for m in match_docs:
        other_id = m["user_b"] if m["user_a"] == target_uid else m["user_a"]
        other = await get_user_doc(app.state.db, other_id)
        record = dict(m)
        record["other_user_id"] = other_id
        record["other_display_name"] = other.get("display_name")
        record["simulation"] = await get_match_simulations(app.state.db, m["id"])
        serialized_matches.append(record)

    counterpart_cache: dict[str, dict] = {}
    dm_threads: dict[str, dict[str, Any]] = {}
    for message in message_rows:
        counterpart_id = message["to_user_id"] if message["from_user_id"] == target_uid else message["from_user_id"]
        counterpart = counterpart_cache.get(counterpart_id)
        if counterpart is None:
            counterpart = await get_user_doc(app.state.db, counterpart_id)
            counterpart_cache[counterpart_id] = counterpart

        thread = dm_threads.setdefault(counterpart_id, {
            "counterpart_user_id": counterpart_id,
            "counterpart_display_name": counterpart.get("display_name") or "",
            "messages": [],
        })
        thread["messages"].append(message)

    return {
        "user": user_doc,
        "stats": {
            "skills": len(skills_rows),
            "questions": len(questions_rows),
            "memories": len(memories_rows),
            "media": len(media_rows),
            "notifications": len(notifications_rows),
            "messages": len(message_rows),
            "matches": len(match_docs),
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
        "messages": message_rows,
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
    profile = await get_user_doc(app.state.db, uid)
    current_content = profile.get(column) or ""

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

    await update_user_doc(app.state.db, uid, {column: updated_wiki})

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
    profile_private: str | None = None
    profile_public_locked: bool | None = None
    profile_public_user_edited: bool | None = None
    profile_public_pending: str | None = None
    community_profile: str | None = None
    agent_name: str | None = None
    voice_preference: str | None = None
    matching_prefs: dict | None = None

@app.get("/profile")
async def get_profile(uid: str = Depends(verify_token)):
    db = app.state.db
    row = await get_user_doc(db, uid)
    if not row:
        display_name = "User"
        try:
            user_record = auth.get_user(uid)
            if user_record.display_name:
                display_name = user_record.display_name
        except Exception:
            pass
        row = await ensure_user_doc(db, uid, display_name)
    return row

@app.post("/profile")
async def update_profile(body: ProfileUpdateBody, uid: str = Depends(verify_token)):
    db = app.state.db
    fields = body.model_dump(exclude_unset=True)
    if not fields:
        return {"success": True}

    existing = await get_user_doc(db, uid)
    if not existing:
        display_name = fields.get("display_name") or "User"
        try:
            user_record = auth.get_user(uid)
            if user_record.display_name and "display_name" not in fields:
                display_name = user_record.display_name
        except Exception:
            pass
        await ensure_user_doc(db, uid, display_name)

    await update_user_doc(db, uid, fields)
    return {"success": True}

@app.get("/profile/{userId}/public")
async def get_public_profile(userId: str, uid: str = Depends(verify_token)):
    doc = await get_user_doc(app.state.db, userId)
    if not doc:
        raise HTTPException(status_code=404, detail="Public profile not found")

    data = {
        "id": doc.get("id"),
        "display_name": doc.get("display_name"),
        "age": doc.get("age"),
        "gender": doc.get("gender"),
        "location_region": doc.get("location_region"),
        "profile_public": doc.get("profile_public"),
        "photo_order": doc.get("photo_order"),
    }

    media_rows = await list_user_media(app.state.db, userId, limit=MATCHES_MEDIA_LIMIT)
    photos = [row["photo_url"] for row in media_rows if row.get("photo_url")]
    data["photos"] = photos

    photo_order = data.get("photo_order") or []
    if photo_order:
        if not photos:
            photos = [u for u in photo_order if isinstance(u, str) and u.strip()]
        else:
            rank = {url: i for i, url in enumerate(photo_order)}
            photos.sort(key=lambda u: rank.get(u, 999999))
        data["photos"] = photos

    data.pop("photo_order", None)
    return data

@app.get("/insights")
async def get_insights(uid: str = Depends(verify_token)):
    profile = await get_user_doc(app.state.db, uid)
    if not profile:
        return {}

    media_rows = await list_user_media(app.state.db, uid, limit=INSIGHTS_MEDIA_LIMIT)
    media_lines = []
    for mr in media_rows:
        date_str = str(mr.get("created_at") or "")[:10]
        line = f"- [{date_str}]({mr['photo_url']})"
        if mr.get("caption"):
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
    db = app.state.db

    match_docs = await get_matches_for_user(db, uid)
    match_docs.sort(key=lambda m: m.get("updated_at") or "", reverse=True)

    other_ids = []
    seen_other_ids: set[str] = set()
    for match in match_docs:
        other_id = match["user_b"] if match["user_a"] == uid else match["user_a"]
        if other_id not in seen_other_ids:
            seen_other_ids.add(other_id)
            other_ids.append(other_id)

    other_docs_list = await asyncio.gather(*[get_user_doc(db, other_id) for other_id in other_ids])
    other_docs = {other_id: doc for other_id, doc in zip(other_ids, other_docs_list)}

    matches = []
    for match in match_docs:
        other_id = match["user_b"] if match["user_a"] == uid else match["user_a"]
        other = other_docs.get(other_id, {})
        media_rows = await list_user_media(db, other_id, limit=1)

        matches.append({
            "id": match["id"],
            "user_a": match.get("user_a"),
            "user_b": match.get("user_b"),
            "score": match.get("score"),
            "created_at": match.get("created_at"),
            "rationale": match.get("rationale"),
            "summary_a": match.get("summary_a"),
            "summary_b": match.get("summary_b"),
            "status": match.get("status"),
            "show_simulation_transcript": match.get("show_simulation_transcript"),
            "synergy_score": match.get("synergy_score"),
            "synergy_summary": match.get("synergy_summary"),
            "other_id": other_id,
            "other_display_name": other.get("display_name"),
            "other_age": other.get("age"),
            "other_gender": other.get("gender"),
            "other_location_region": other.get("location_region"),
            "other_profile_public": other.get("profile_public"),
            "other_photo_url": media_rows[0]["photo_url"] if media_rows else "",
        })

    return matches

@app.post("/matches/{pair_id}/status")
async def update_match_status(pair_id: str, body: MatchStatusBody, uid: str = Depends(verify_token)):
    db = app.state.db
    match = await get_match_doc(db, pair_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match not found")
    if uid not in (match.get("user_a"), match.get("user_b")):
        raise HTTPException(status_code=403, detail="Not your match")

    await _match_doc_ref(db, pair_id).set(
        {
            "status": body.status,
            "updated_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )
    return {"success": True}

# ── Notifications Endpoints ───────────────────────────────────────────────────

@app.get("/notifications")
async def get_notifications(uid: str = Depends(verify_token)):
    return await get_notifications_for_user(app.state.db, uid, limit=NOTIFICATIONS_LIMIT)

@app.post("/notifications/{notif_id}/read")
async def mark_notification_read(notif_id: str, uid: str = Depends(verify_token)):
    await mark_notification_read_doc(app.state.db, uid, notif_id)
    return {"success": True}

@app.post("/notifications/read-all")
async def mark_all_notifications_read(uid: str = Depends(verify_token)):
    await mark_all_notifications_read_docs(app.state.db, uid)
    return {"success": True}

# ── Profile Answers & Questions Checklist ──────────────────────────────────────

class ProfileAnswerBody(BaseModel):
    field_id: str
    value: Any

class FollowupQuestionBody(BaseModel):
    question: str

@app.get("/profile/answers")
async def get_profile_answers(uid: str = Depends(verify_token)):
    doc = await get_user_doc(app.state.db, uid)
    return doc.get("profile_answers") or {}

@app.post("/profile/answers")
async def save_profile_answer(body: ProfileAnswerBody, uid: str = Depends(verify_token)):
    doc = await get_user_doc(app.state.db, uid)
    if not doc:
        raise HTTPException(status_code=404, detail="User not found")

    profile_answers = dict(doc.get("profile_answers") or {})
    public_map = dict(doc.get("profile_answers_public") or {})
    private_map = dict(doc.get("profile_answers_private") or {})
    sensitive_map = dict(doc.get("profile_answers_sensitive") or {})
    visibility_map = dict(doc.get("profile_field_visibility") or {})

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

    await update_user_doc(
        app.state.db,
        uid,
        {
            "profile_answers": profile_answers,
            "profile_answers_public": public_map,
            "profile_answers_private": private_map,
            "profile_answers_sensitive": sensitive_map,
            "profile_field_visibility": visibility_map,
            "wiki_profile_structured": structured_wiki,
            "explore_attrs": _build_explore_attrs(public_map),
        },
    )

    await mark_user_questions_answered_by_keys(app.state.db, uid, {field_id})

    return {"success": True}

@app.get("/questions/pending")
async def get_pending_questions(uid: str = Depends(verify_token)):
    return await get_pending_user_questions(app.state.db, uid)

@app.post("/questions/followup")
async def add_followup_question(body: FollowupQuestionBody, uid: str = Depends(verify_token)):
    qid = f"followup_{int(datetime.now().timestamp())}"
    await add_followup_question_doc(app.state.db, uid, qid, body.question)
    return {"success": True}

@app.post("/questions/{qid}/answered")
async def mark_question_answered(qid: str, uid: str = Depends(verify_token)):
    await mark_question_answered_doc(app.state.db, uid, qid)
    return {"success": True}

# ── Explore ───────────────────────────────────────────────────────────────────

EXPLORE_FILTER_FIELD_IDS = (
    "religion",
    "race",
    "height_cm",
    "education_level",
    "occupation",
    "skin_tone",
    "diet",
    "tribe_ethnicity",
    "religious_sect",
    "location_city",
    "marital_status",
    "relationship_intent",
    "religious_practice_level",
    "caste",
    "mother_tongue",
    "language_spoken",
)

EXPLORE_PREFETCH_LIMIT = max(EXPLORE_LIMIT * 4, 200)

_EXPLORE_QUERY_PROMPT = """Parse this people-search query for a matchmaking app into structured filters.

Allowed filter field IDs (only include when explicitly mentioned or strongly implied):
{field_catalog}

Return JSON only:
{{
  "filters": {{ "field_id": "value" or ["value1", "value2"] or {{"min": number, "max": number}} }},
  "text_terms": ["remaining tokens to match against name, bio, or location"]
}}

Rules:
- Normalize religion, race, diet, and occupation to simple lowercase strings.
- For height, prefer cm as {{"min": N, "max": M}} when a range is implied.
- If the query is only a name or interest phrase, leave filters empty and use text_terms.
- Never invent filters that are not supported by the query.
"""


def _normalize_explore_value(value) -> str | list[str]:
    if isinstance(value, list):
        return [str(v).strip().lower() for v in value if str(v).strip()]
    return str(value).strip().lower()


def _build_explore_attrs(public_map: dict) -> dict:
    attrs: dict = {}
    for field_id in EXPLORE_FILTER_FIELD_IDS:
        raw = public_map.get(field_id)
        if raw in (None, "", [], {}):
            continue
        attrs[field_id] = _normalize_explore_value(raw)
    return attrs


def _candidate_explore_attrs(doc: dict) -> dict:
    attrs = dict(doc.get("explore_attrs") or {})
    if attrs:
        return attrs
    return _build_explore_attrs(_parse_json_field(doc.get("profile_answers_public")))


def _explore_text_blob(doc: dict) -> str:
    parts = [
        doc.get("display_name") or "",
        doc.get("profile_public") or "",
        doc.get("location_region") or "",
    ]
    for value in _candidate_explore_attrs(doc).values():
        if isinstance(value, list):
            parts.extend(str(v) for v in value)
        else:
            parts.append(str(value))
    return " ".join(p.strip() for p in parts if p and str(p).strip()).lower()


def _attr_value_matches(candidate_value, filter_value) -> bool:
    if filter_value in (None, "", [], {}):
        return True

    if isinstance(filter_value, dict) and ("min" in filter_value or "max" in filter_value):
        try:
            candidate_num = float(candidate_value)
        except (TypeError, ValueError):
            return False
        min_val = filter_value.get("min")
        max_val = filter_value.get("max")
        if min_val is not None and candidate_num < float(min_val):
            return False
        if max_val is not None and candidate_num > float(max_val):
            return False
        return True

    candidate_norm = _normalize_explore_value(candidate_value)
    filter_norm = _normalize_explore_value(filter_value)

    if isinstance(candidate_norm, list):
        if isinstance(filter_norm, list):
            return any(f in candidate_norm or any(f in c for c in candidate_norm) for f in filter_norm)
        return filter_norm in candidate_norm or any(filter_norm in c for c in candidate_norm)

    if isinstance(filter_norm, list):
        return any(f in candidate_norm or candidate_norm in f for f in filter_norm)

    return (
        filter_norm == candidate_norm
        or filter_norm in candidate_norm
        or candidate_norm in filter_norm
    )


def _matches_explore_filters(
    doc: dict,
    *,
    parsed_filters: dict,
    text_terms: list[str],
) -> bool:
    attrs = _candidate_explore_attrs(doc)
    for field_id, filter_value in parsed_filters.items():
        if field_id not in EXPLORE_FILTER_FIELD_IDS:
            continue
        if not _attr_value_matches(attrs.get(field_id), filter_value):
            return False

    if not text_terms:
        return True

    blob = _explore_text_blob(doc)
    return all(term.strip().lower() in blob for term in text_terms if term.strip())


def _coords_from_doc(doc: dict) -> tuple[float, float] | None:
    coords = _parse_json_field(doc.get("location_coords"))
    lat = coords.get("lat")
    lng = coords.get("lng")
    if lat is None or lng is None:
        return None
    try:
        return float(lat), float(lng)
    except (TypeError, ValueError):
        return None


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _within_radius_km(
    viewer_coords: tuple[float, float] | None,
    candidate_doc: dict,
    radius_km: int | None,
) -> bool:
    if radius_km is None or radius_km <= 0 or viewer_coords is None:
        return True
    candidate_coords = _coords_from_doc(candidate_doc)
    if candidate_coords is None:
        return True
    distance = _haversine_km(viewer_coords[0], viewer_coords[1], candidate_coords[0], candidate_coords[1])
    return distance <= float(radius_km)


def _explore_field_catalog() -> str:
    lines = []
    for field_id in EXPLORE_FILTER_FIELD_IDS:
        meta = PROFILE_FIELD_META.get(field_id, {})
        question = meta.get("question_text") or field_id
        lines.append(f"- {field_id}: {question}")
    return "\n".join(lines)


async def _parse_explore_query(query: str) -> tuple[dict, list[str]]:
    cleaned = (query or "").strip()
    if not cleaned:
        return {}, []

    prompt = _EXPLORE_QUERY_PROMPT.format(field_catalog=_explore_field_catalog())
    try:
        raw = await _gemini_call(
            TEXT_MODEL,
            f"Search query: {cleaned}",
            system_instruction=prompt,
            generation_config={"response_mime_type": "application/json"},
        )
        payload = json.loads(raw)
    except Exception as e:
        logger.warning(f"[explore] query parse failed: {type(e).__name__}: {e}")
        return {}, _fallback_explore_text_terms(cleaned)

    filters = payload.get("filters") or {}
    if not isinstance(filters, dict):
        filters = {}

    text_terms = payload.get("text_terms") or []
    if not isinstance(text_terms, list):
        text_terms = []
    text_terms = [str(term).strip().lower() for term in text_terms if str(term).strip()]

    if not filters and not text_terms:
        text_terms = [cleaned.lower()]

    return filters, text_terms


def _fallback_explore_text_terms(query: str) -> list[str]:
    stopwords = {
        "a",
        "an",
        "and",
        "are",
        "by",
        "for",
        "in",
        "likes",
        "like",
        "of",
        "or",
        "the",
        "to",
        "who",
        "with",
    }
    terms = [
        term
        for term in re.findall(r"[a-z0-9]+", query.lower())
        if len(term) > 2 and term not in stopwords
    ]
    return terms or [query.strip().lower()]


def _pick_firestore_attr_filter(parsed_filters: dict) -> tuple[str, object] | None:
    priority = (
        "religion",
        "race",
        "education_level",
        "occupation",
        "location_city",
        "diet",
        "relationship_intent",
    )
    for field_id in priority:
        value = parsed_filters.get(field_id)
        if value in (None, "", [], {}):
            continue
        if isinstance(value, dict):
            continue
        if isinstance(value, list):
            if not value:
                continue
            return field_id, value[0]
        return field_id, value
    return None


@app.get("/explore")
async def explore(
    gender: str | None = None,
    ageMin: int | None = None,
    ageMax: int | None = None,
    radiusKm: int | None = None,
    query: str | None = None,
    uid: str = Depends(verify_token),
):
    db = app.state.db
    if query and len(query) > 100:
        raise HTTPException(status_code=400, detail="query too long")
    gender = _normalize_gender_filter(gender)
    viewer = await get_user_doc(db, uid)
    viewer_coords = _coords_from_doc(viewer) if viewer else None

    parsed_filters: dict = {}
    text_terms: list[str] = []
    if query and query.strip():
        parsed_filters, text_terms = await _parse_explore_query(query)

    q = db.collection("users").where(filter=FieldFilter("onboarding_complete", "==", True))

    if gender:
        q = q.where(filter=FieldFilter("gender", "==", gender))
    if ageMin is not None:
        q = q.where(filter=FieldFilter("age", ">=", ageMin))
    if ageMax is not None:
        q = q.where(filter=FieldFilter("age", "<=", ageMax))

    firestore_attr = _pick_firestore_attr_filter(parsed_filters)
    if firestore_attr:
        field_id, value = firestore_attr
        q = q.where(filter=FieldFilter(f"explore_attrs.{field_id}", "==", _normalize_explore_value(value)))

    needs_post_filter = bool(
        (parsed_filters and (not firestore_attr or len(parsed_filters) > 1))
        or text_terms
        or (radiusKm is not None and radiusKm > 0 and viewer_coords is not None)
    )
    fetch_limit = EXPLORE_PREFETCH_LIMIT if needs_post_filter else EXPLORE_LIMIT
    q = q.limit(fetch_limit)

    people = []
    async for snap in q.stream():
        if snap.id == uid:
            continue

        doc = parse_user_doc(snap)
        if not _within_radius_km(viewer_coords, doc, radiusKm):
            continue
        if not _matches_explore_filters(doc, parsed_filters=parsed_filters, text_terms=text_terms):
            continue

        p = {
            "id": doc.get("id"),
            "display_name": doc.get("display_name"),
            "age": doc.get("age"),
            "gender": doc.get("gender"),
            "location_region": doc.get("location_region"),
            "profile_public": doc.get("profile_public"),
            "photo_order": doc.get("photo_order"),
        }
        photo_order = p.get("photo_order") or []
        p["photo_order"] = [u for u in photo_order if isinstance(u, str) and u.strip()]
        people.append(p)
        if len(people) >= EXPLORE_LIMIT:
            break

    for p in people:
        media_rows = await list_user_media(db, p["id"], limit=1)
        p["photo_url"] = media_rows[0]["photo_url"] if media_rows else ""
        if not p["photo_url"] and p["photo_order"]:
            p["photo_url"] = p["photo_order"][0]

    return people


def _normalize_gender_filter(gender: str | None) -> str | None:
    value = (gender or "").strip().lower()
    if not value:
        return None
    if value in ("men", "male"):
        return "man"
    if value in ("women", "female"):
        return "woman"
    return value

# ── User Media Endpoints ───────────────────────────────────────────────────────

class MediaBody(BaseModel):
    photo_url: str
    caption: str | None = None

class MediaDeleteBody(BaseModel):
    photo_url: str

@app.post("/media")
async def save_media_record(body: MediaBody, uid: str = Depends(verify_token)):
    await save_user_media(app.state.db, uid, body.photo_url, body.caption)
    return {"success": True}

@app.delete("/media")
async def delete_media_by_url(body: MediaDeleteBody, uid: str = Depends(verify_token)):
    await delete_user_media_by_url_doc(app.state.db, uid, body.photo_url)
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
            await update_user_doc(app.state.db, uid, {"matching_paused": True})
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
            profile = await get_user_doc(app.state.db, uid)
            current = profile.get("wiki_about_me") or ""
            lines = [
                line for line in current.split("\n")
                if not any(key in line.lower() for key in ("score:", "strengths:", "improve:", "best feature:", "impression:"))
            ]
            appearance_block = f"## Appearance Assessment\n{description}"
            updated = (appearance_block + "\n\n" + "\n".join(lines)).strip()
            await update_user_doc(app.state.db, uid, {"wiki_about_me": updated})
    except Exception as e:
        logger.warning(f"analyze-photos failed: {e}")
    return {"success": True}

# ── Device token endpoint (FCM registration) ──────────────────────────────────

class DeviceTokenBody(BaseModel):
    token: str

@app.post("/device-token")
async def save_device_token(body: DeviceTokenBody, uid: str = Depends(verify_token)):
    """Save the device's FCM token so the backend can send push notifications."""
    await update_user_doc(app.state.db, uid, {"fcm_token": body.token})
    logger.info(f"FCM token registered for {uid}")
    return {"success": True}

# ── Direct Messaging Endpoints ─────────────────────────────────────────────────

class MessageBody(BaseModel):
    target_user_id: str
    text: str

@app.post("/messages")
async def send_direct_message(body: MessageBody, uid: str = Depends(verify_token)):
    db = app.state.db
    await send_message(db, uid, body.target_user_id, body.text)
    me = await get_user_doc(db, uid)
    my_name = me.get("display_name") or "Someone"
    notif_body = f"{my_name} sent you a message."
    await create_notification(
        db,
        body.target_user_id,
        "agent_update",
        "New message",
        notif_body,
        {"from_user_id": uid},
    )

    recipient = await get_user_doc(db, body.target_user_id)
    recipient_token = recipient.get("fcm_token") or ""

    asyncio.create_task(_send_push(
        recipient_token, f"Message from {my_name}",
        body.text[:PUSH_PREVIEW_LEN], {"from_user_id": uid, "type": "dm"},
    ))
    return {"success": True}

@app.get("/messages/{other_user_id}")
async def get_messages(other_user_id: str, uid: str = Depends(verify_token)):
    db = app.state.db
    msgs = await get_conversation_messages(db, uid, other_user_id)
    return msgs

# ── Text Chat Endpoint ─────────────────────────────────────────────────────────

class TextChatRequest(BaseModel):
    messages: list[dict]  # [{"role": "user"|"model", "text": "..."}]

@app.post("/chat/text")
@limiter.limit(RATE_CHAT_TEXT)
async def text_chat(request: Request, body: TextChatRequest, uid: str = Depends(verify_token)):
    """Text-mode chat with Ayma — uses same system prompt as voice bootstrap.
    Useful for testing conversation quality without Gemini Live WebSocket."""
    db = app.state.db
    profile = await get_user_doc(db, uid)
    if not profile:
        raise HTTPException(status_code=404, detail="User not found")
    active_questions = _active_questions_for_profile(profile)
    answered_keys = _answered_question_keys_from_profile(profile)
    skills = await get_enabled_skills(db, uid)
    await seed_user_questions_if_empty(db, uid, active_questions, answered_keys)
    pending_questions = await get_pending_user_questions(db, uid)

    if not body.messages:
        raise HTTPException(status_code=400, detail="No messages provided")

    system_prompt = _build_system_prompt(profile, skills, pending_questions)
    contents = []
    for m in body.messages:
        text = (m.get("text") or "").strip()
        if not text:
            continue
        role = "user" if m.get("role") == "user" else "model"
        contents.append({"role": role, "parts": [{"text": text}]})
    if not contents:
        raise HTTPException(status_code=400, detail="No text messages provided")

    try:
        text = await _gemini_call(
            TEXT_MODEL,
            contents,
            system_instruction=system_prompt,
        )
        return {"role": "model", "text": text or ""}
    except Exception as e:
        if _is_quota_error(e):
            logger.warning(f"[/chat/text] Gemini quota exhausted: {type(e).__name__}: {e}")
            raise HTTPException(status_code=429, detail="Quota exhausted")
        logger.exception("[/chat/text] Gemini generation failed")
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

async def _run_vibe_check(db, pid: str, uid_a: str, uid_b: str) -> dict:
    """Simulate a 5-turn first-date conversation and return synergy score + summary."""
    profile_a = await get_user_doc(db, uid_a)
    profile_b = await get_user_doc(db, uid_b)

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

    # Parse dialogue and write to the matches/{pairId}/simulations subcollection
    turns: list[dict] = []
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
                turns.append({
                    "sender_uid": uid_a,
                    "turn_index": turn_idx,
                    "message_text": text,
                })
                turn_idx += 1
        elif line.startswith('B:') or line.startswith('Person B:'):
            parts = line.split(':', 1)
            if len(parts) > 1:
                text = parts[1].strip()
                turns.append({
                    "sender_uid": uid_b,
                    "turn_index": turn_idx,
                    "message_text": text,
                })
                turn_idx += 1

    await replace_match_simulations(db, pid, turns)

    return {
        "synergy_score": max(0, min(100, synergy_score)),
        "synergy_summary": synergy_summary
    }

# ── Matching & Simulation Endpoints ──────────────────────────────────────────────

@app.post("/run-matching")
@limiter.limit(RATE_RUN_MATCHING)
async def run_matching(request: Request, uid: str = Depends(verify_token)):
    db = app.state.db
    model = None  # _score_pair and _run_vibe_check now use _gemini_call internally

    me = await get_user_doc(db, uid)
    if not me:
        raise HTTPException(status_code=404, detail="Profile not found")

    existing_matches = await get_matches_for_user(db, uid)
    excluded_ids = {
        match["user_b"] if match["user_a"] == uid else match["user_a"]
        for match in existing_matches
    }

    candidates = []
    query = (
        db.collection("users")
        .where(filter=FieldFilter("onboarding_complete", "==", True))
        .where(filter=FieldFilter("matching_paused", "==", False))
        .limit(MATCH_CANDIDATE_POOL)
    )
    # Approximates the old SQL NOT IN filter: Firestore applies LIMIT before the
    # client-side self/excluded filtering, so fewer candidates may remain.
    async for snap in query.stream():
        if snap.id == uid or snap.id in excluded_ids:
            continue
        candidates.append(parse_user_doc(snap))

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
    my_name = me.get("display_name") or "Someone"

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

        # Always reset synergy fields here (mirrors the old SQL, which reset
        # them to NULL on every conflict-update unless immediately overwritten
        # by the vibe-check branch below) — otherwise merge=True would keep a
        # stale synergy score from a previous run.
        pid = await upsert_match_doc(db, user_a, user_b, {
            "score": score,
            "rationale": scoring.get("rationale", ""),
            "summary_a": db_summary_a,
            "summary_b": db_summary_b,
            "status": "pending",
            "synergy_score": None,
            "synergy_summary": "",
        })

        if cuid in vibe_uids:
            vibe = await _run_vibe_check(db, pid, uid, cuid)
            synergy_score = vibe["synergy_score"]
            synergy_summary = vibe["synergy_summary"]

            final_score = round(score * FINAL_SCORE_COMPAT_WEIGHT + (synergy_score / 100) * (1 - FINAL_SCORE_COMPAT_WEIGHT), 3)

            await upsert_match_doc(db, user_a, user_b, {
                "score": final_score,
                "synergy_score": synergy_score,
                "synergy_summary": synergy_summary,
                "status": "vibe_checked",
            })

        created += 1
        # Push notification: tell the other user they have a new match
        other_token = candidate.get("fcm_token") or ""
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
    db = app.state.db
    total_created = 0

    user_ids = []
    user_query = (
        db.collection("users")
        .where(filter=FieldFilter("onboarding_complete", "==", True))
        .where(filter=FieldFilter("matching_paused", "==", False))
    )
    async for snap in user_query.stream():
        user_ids.append(snap.id)

    logger.info(f"[cron] Running matching for {len(user_ids)} users")
    for uid in user_ids:
        try:
            me = await get_user_doc(db, uid)
            if not me:
                continue

            existing_matches = await get_matches_for_user(db, uid)
            excluded_ids = {
                match["user_b"] if match["user_a"] == uid else match["user_a"]
                for match in existing_matches
            }

            candidates = []
            query = (
                db.collection("users")
                .where(filter=FieldFilter("onboarding_complete", "==", True))
                .where(filter=FieldFilter("matching_paused", "==", False))
                .limit(CRON_CANDIDATE_POOL)
            )
            async for snap in query.stream():
                if snap.id == uid or snap.id in excluded_ids:
                    continue
                candidates.append(parse_user_doc(snap))

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
                existing = await get_match_doc(db, _pair_id(ua, ub))
                if existing:
                    continue  # ON CONFLICT (user_a, user_b) DO NOTHING equivalent
                await upsert_match_doc(db, ua, ub, {
                    "score": round(float(scoring.get("score", 0)), 3),
                    "rationale": scoring.get("rationale", ""),
                    "summary_a": sa,
                    "summary_b": sb,
                    "status": "pending",
                })
                total_created += 1
        except Exception as e:
            logger.warning(f"[cron] matching failed for {uid}: {e}")
    logger.info(f"[cron] Matching complete: {total_created} new matches")
    return {"total_matches_created": total_created, "users_processed": len(user_ids)}

class VibeCheckRequest(BaseModel):
    pair_id: str

@app.post("/vibe-check")
async def vibe_check(body: VibeCheckRequest, uid: str = Depends(verify_token)):
    db = app.state.db
    match = await get_match_doc(db, body.pair_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match not found")

    uid_a = match.get("user_a")
    uid_b = match.get("user_b")

    if uid not in (uid_a, uid_b):
        raise HTTPException(status_code=403, detail="Not your match")

    other_uid = uid_b if uid == uid_a else uid_a
    result = await _run_vibe_check(db, body.pair_id, uid, other_uid)
    synergy_score = result["synergy_score"]
    synergy_summary = result["synergy_summary"]

    compat_score = float(match.get("score") or 0.0)
    final_score = round(compat_score * FINAL_SCORE_COMPAT_WEIGHT + (synergy_score / 100) * (1 - FINAL_SCORE_COMPAT_WEIGHT), 3)

    await _match_doc_ref(db, body.pair_id).set(
        {
            "score": final_score,
            "synergy_score": synergy_score,
            "synergy_summary": synergy_summary,
            "status": "vibe_checked",
            "updated_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    return {
        "synergy_score": synergy_score,
        "synergy_summary": synergy_summary
    }

@app.get("/matches/{pair_id}/simulation")
async def get_match_simulation(pair_id: str, uid: str = Depends(verify_token)):
    db = app.state.db
    match = await get_match_doc(db, pair_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match not found")

    if uid not in (match["user_a"], match["user_b"]):
        raise HTTPException(status_code=403, detail="Not authorized to view this match simulation")

    if not match.get("show_simulation_transcript"):
        return []

    return await get_match_simulations(db, pair_id)

class ToggleSimulationBody(BaseModel):
    show_simulation_transcript: bool

@app.post("/matches/{pair_id}/toggle-simulation")
async def toggle_match_simulation(pair_id: str, body: ToggleSimulationBody, uid: str = Depends(verify_token)):
    db = app.state.db
    match = await get_match_doc(db, pair_id)
    if not match:
        raise HTTPException(status_code=404, detail="Match not found")
    if uid not in (match["user_a"], match["user_b"]):
        raise HTTPException(status_code=403, detail="Not authorized")

    await _match_doc_ref(db, pair_id).set(
        {
            "show_simulation_transcript": body.show_simulation_transcript,
            "updated_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )

    return {"success": True}
