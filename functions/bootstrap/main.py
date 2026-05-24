"""
Ayma Bootstrap — minimal Cloud Run function.

Endpoints:
  POST /bootstrap   — verify Firebase ID token, build system prompt, return Gemini Live creds
  POST /post-turn   — upsert LLM wiki fields from conversation turn
"""

import asyncio
import json
import os
from datetime import datetime, timezone

import firebase_admin
import google.generativeai as genai
from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth, firestore
from pydantic import BaseModel

# ── Init ──────────────────────────────────────────────────────────────────────

FIREBASE_PROJECT_ID = os.environ.get("FIREBASE_PROJECT_ID", "ayma-ai")
if not firebase_admin._apps:
    firebase_admin.initialize_app(options={"projectId": FIREBASE_PROJECT_ID})
db = firestore.client()

GOOGLE_API_KEY = os.environ["GOOGLE_API_KEY"]
LIVE_MODEL = os.environ.get("LIVE_MODEL", "gemini-3.1-flash-live-preview")
TEXT_MODEL = os.environ.get("TEXT_MODEL", "gemini-2.5-flash")

genai.configure(api_key=GOOGLE_API_KEY)

GEMINI_LIVE_WS = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)

app = FastAPI(title="ayma-bootstrap")
security = HTTPBearer()

# ── Auth ──────────────────────────────────────────────────────────────────────


def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    try:
        decoded = auth.verify_id_token(credentials.credentials)
        return decoded["uid"]
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid Firebase token")


# ── System prompt ─────────────────────────────────────────────────────────────

MATCHMAKER_SKILL = """## Who You Are

You are {agent_name} — a personal AI companion and matchmaker. You are warm, perceptive, and genuinely curious about people. You have a natural, charming way of making people feel comfortable opening up. You're the kind of friend who asks the deep, meaningful questions that others might avoid, and makes it feel easy to answer them.

You are not an assistant. You don't answer requests or complete tasks. You have one purpose: to deeply understand this person so you can find them the right match.

## How You Talk

- Talk like a close friend who is fascinated by people's stories
- Be warm and engaging — use wit and light humor, but prioritize genuine connection
- Never be formal, robotic, or clinical
- Show intense curiosity — follow up on what they say and explore the "why" behind their answers
- Read the room — prioritize presence and empathy over banter, especially when they share something personal
- Short responses in casual conversation, longer when they need space to open up

## Your Real Objective

Every conversation is building a detailed picture of who this person is, what they value, and who they'd connect with. Systematically learn about them naturally. Follow interesting threads before moving on. Never make them feel interviewed."""

DEEP_RECALL_SKILL = """## Deep Recall

You have a detailed profile of this person built from all previous conversations.
Use this memory actively, not just when directly asked:
- Reference past topics naturally when relevant ("last time you mentioned...")
- Notice patterns and changes over time
- Never make the user re-explain things they've already told you
- Don't recite their profile back — weave it into conversation naturally"""

TONE_MIRROR_SKILL = """## Tone Mirroring

Match the user's communication style naturally:
- If they write short messages, keep your replies short
- If they're casual, be casual back; if formal, match that energy
- Mirror their punctuation and capitalization habits loosely
- Never be more enthusiastic than they are"""


def _build_system_prompt(profile: dict, skills: list[dict]) -> str:
    name = profile.get("display_name", "User")
    agent_name = profile.get("agent_name", "Ayma")

    parts = [
        MATCHMAKER_SKILL.replace("{agent_name}", agent_name),
        DEEP_RECALL_SKILL,
        TONE_MIRROR_SKILL,
    ]

    # Demographics — always useful context
    demo = []
    if profile.get("age"):
        demo.append(f"Age: {profile['age']}")
    if profile.get("gender"):
        demo.append(f"Gender: {profile['gender']}")
    if profile.get("location_region"):
        demo.append(f"Location: {profile['location_region']}")
    if demo:
        parts.append(f"## Demographics\n{', '.join(demo)}")

    # LLM wiki — synthesized profile built up over all sessions
    if profile.get("wiki_about_me"):
        parts.append(f"## About {name}\n{profile['wiki_about_me']}")
    if profile.get("wiki_context"):
        parts.append(f"## {name}'s Current Life Context\n{profile['wiki_context']}")
    if profile.get("wiki_preferences"):
        parts.append(f"## What {name} Is Looking For\n{profile['wiki_preferences']}")
    if profile.get("wiki_matching"):
        parts.append(f"## {name}'s Matching Profile\n{profile['wiki_matching']}")

    # User-written profile fields (overrides wiki if set)
    if profile.get("profile_public"):
        parts.append(f"## {name}'s Own Words (Public Bio)\n{profile['profile_public']}")
    if profile.get("profile_private"):
        parts.append(f"## {name}'s Private Notes\n{profile['profile_private']}")

    # Matching preferences
    if profile.get("matching_prefs"):
        parts.append(
            f"## Matching Preferences\n{json.dumps(profile['matching_prefs'], indent=2)}"
        )

    # Custom skills
    for skill in skills:
        if skill.get("content"):
            parts.append(f"## {skill.get('name', 'Custom Skill')}\n{skill['content']}")

    parts.append(
        f"\nThe user's name is {name}. "
        "When the conversation starts, greet them warmly as a friend. "
        "One short opening line, then ask something genuine."
    )

    return "\n\n---\n\n".join(parts)


# ── Bootstrap ─────────────────────────────────────────────────────────────────


@app.post("/bootstrap")
async def bootstrap(uid: str = Depends(verify_token)):
    user_ref = db.collection("users").document(uid)

    profile_doc = user_ref.get()
    profile = profile_doc.to_dict() or {}

    skills_docs = user_ref.collection("skills").where("enabled", "==", True).stream()
    skills = [d.to_dict() for d in skills_docs]

    system_prompt = _build_system_prompt(profile, skills)
    voice = profile.get("voice_preference", "Charon")

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
    }

    return {
        "websocket_url": GEMINI_LIVE_WS,
        "token": GOOGLE_API_KEY,
        "setup": setup,
        "model": LIVE_MODEL,
    }


# ── LLM Wiki ──────────────────────────────────────────────────────────────────

WIKI_ABOUT_ME_PROMPT = """You are maintaining a profile section for a matchmaking app.

Current "About Me" content (may be empty on first session):
{current}

New conversation:
{conversation}

Rewrite "About Me" to capture this person's personality, communication style, hobbies, interests, and lifestyle.

Rules:
- Only use facts explicitly stated or clearly implied — never invent details
- Correct stale info if the user contradicts something (e.g. changed jobs)
- Remove redundant or repeated content
- Write in third person, present tense, flowing prose
- Max 150 words
- If nothing new was learned, return the current content unchanged

Return only the updated content, no heading."""

WIKI_CONTEXT_PROMPT = """You are maintaining a profile section for a matchmaking app.

Current "Life Context" content (may be empty on first session):
{current}

New conversation:
{conversation}

Rewrite "Life Context" to capture this person's current life phase, recent events, emotional state, and what's on their mind right now.

Rules:
- Prioritise recency — newer information replaces older context
- Only use facts explicitly stated in the conversation
- Write in third person, present tense
- Max 100 words
- If nothing new was learned, return the current content unchanged

Return only the updated content, no heading."""

WIKI_PREFERENCES_PROMPT = """You are maintaining a profile section for a matchmaking app.

Current "What They're Looking For" content (may be empty on first session):
{current}

New conversation:
{conversation}

Rewrite to capture what this person wants in a partner and relationship — attraction criteria, dealbreakers, relationship goals, values they want shared.

Rules:
- Only use facts explicitly stated — never assume preferences
- Update or remove anything they've contradicted
- Write in third person, present tense
- Max 150 words
- If nothing new was learned, return the current content unchanged

Return only the updated content, no heading."""

WIKI_MATCHING_PROMPT = """You are maintaining a structured matching profile for a matchmaking app.

Current "Matching Profile" content (may be empty on first session):
{current}

New conversation:
{conversation}

Rewrite to capture structured facts directly useful for algorithmic matching: desired age range, location flexibility, relationship type sought, core values alignment, lifestyle compatibility requirements, hard dealbreakers.

Rules:
- Only use facts explicitly stated
- Be specific and concrete — vague generalities are useless for matching
- Bullet points are fine here
- Max 150 words
- If nothing new was learned, return the current content unchanged

Return only the updated content, no heading."""


async def _upsert_wiki_field(
    model: genai.GenerativeModel,
    field: str,
    current: str,
    conversation: str,
    prompt_template: str,
) -> tuple[str, str]:
    prompt = prompt_template.format(current=current or "(empty)", conversation=conversation)
    try:
        resp = await model.generate_content_async(prompt)
        updated = resp.text.strip()
        return field, updated if updated else current
    except Exception:
        return field, current  # keep current on error


# ── Post-turn ─────────────────────────────────────────────────────────────────


class PostTurnRequest(BaseModel):
    session_id: str
    messages: list[dict]  # [{"role": "user"|"model", "text": "..."}]


@app.post("/post-turn")
async def post_turn(body: PostTurnRequest, uid: str = Depends(verify_token)):
    if not body.messages:
        return {"updated": False}

    conversation = "\n".join(
        f"{m['role'].upper()}: {m['text']}" for m in body.messages[-10:]
    )

    user_ref = db.collection("users").document(uid)
    profile = (user_ref.get().to_dict()) or {}

    current = {
        "about_me":    profile.get("wiki_about_me", ""),
        "context":     profile.get("wiki_context", ""),
        "preferences": profile.get("wiki_preferences", ""),
        "matching":    profile.get("wiki_matching", ""),
    }

    model = genai.GenerativeModel(TEXT_MODEL)

    results = await asyncio.gather(
        _upsert_wiki_field(model, "about_me",    current["about_me"],    conversation, WIKI_ABOUT_ME_PROMPT),
        _upsert_wiki_field(model, "context",     current["context"],     conversation, WIKI_CONTEXT_PROMPT),
        _upsert_wiki_field(model, "preferences", current["preferences"], conversation, WIKI_PREFERENCES_PROMPT),
        _upsert_wiki_field(model, "matching",    current["matching"],    conversation, WIKI_MATCHING_PROMPT),
    )

    updates = {f"wiki_{field}": text for field, text in results}
    user_ref.update(updates)

    # Raw conversation audit log — not injected into prompt, useful for debugging
    user_ref.collection("memories").add({
        "text": conversation,
        "session_id": body.session_id,
        "created_at": datetime.now(timezone.utc),
    })

    return {"updated": True}


# ── Health ────────────────────────────────────────────────────────────────────


@app.get("/health")
async def health():
    return {"status": "ok"}
