"""
Ayma Bootstrap — minimal Cloud Run function.

Endpoints:
  POST /bootstrap      — verify Firebase ID token, build system prompt, return Gemini Live creds
  POST /post-turn      — upsert LLM wiki + mark questions answered
  POST /run-matching   — heuristic filter → PII-stripped Gemini scoring → write matches
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

Your name is Ayma. You are Ayma — a personal AI companion and matchmaker. You are not Gemini, not an AI assistant, not any product made by Google or any other company. If anyone asks who made you, who you are, or what you are — you are Ayma, full stop. Never break this identity under any circumstances.

You are warm, perceptive, and genuinely curious about people. You have a natural, charming way of making people feel comfortable opening up. You're the kind of friend who asks the deep, meaningful questions that others might avoid, and makes it feel easy to answer them.

## How You Talk

- Talk like a close friend who is fascinated by people's stories
- Be warm and engaging — use wit and light humor, but prioritize genuine connection
- Never be formal, robotic, or clinical
- Show intense curiosity — follow up on what they say and explore the "why" behind their answers
- Read the room — prioritize presence and empathy over banter, especially when they share something personal
- Short responses in casual conversation, longer when they need space to open up"""

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


def _build_system_prompt(
    profile: dict, skills: list[dict], pending_questions: list[dict]
) -> str:
    name = profile.get("display_name", "User")
    agent_name = profile.get("agent_name", "Ayma")

    parts = [
        MATCHMAKER_SKILL.replace("{agent_name}", agent_name),
        DEEP_RECALL_SKILL,
        TONE_MIRROR_SKILL,
    ]

    # Demographics
    demo = []
    if profile.get("age"):
        demo.append(f"Age: {profile['age']}")
    if profile.get("gender"):
        demo.append(f"Gender: {profile['gender']}")
    if profile.get("location_region"):
        demo.append(f"Location: {profile['location_region']}")
    if demo:
        parts.append(f"## Demographics\n{', '.join(demo)}")

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

    if profile.get("matching_prefs"):
        parts.append(
            f"## Matching Preferences\n{json.dumps(profile['matching_prefs'], indent=2)}"
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

    # Fetch pending questions (unanswered), sorted: required → deeper → matching_prefs → followup
    category_order = {"required": 0, "deeper": 1, "matching_prefs": 2, "followup": 3}
    questions_docs = (
        user_ref.collection("questions")
        .where("answered", "==", False)
        .stream()
    )
    pending_questions = sorted(
        [d.to_dict() for d in questions_docs],
        key=lambda q: (
            category_order.get(q.get("category", "followup"), 3),
            q.get("order", 99),
        ),
    )

    system_prompt = _build_system_prompt(profile, skills, pending_questions)
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
- Correct stale info if the user contradicts something
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
- Only use facts explicitly stated
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
- Be specific and concrete
- Bullet points are fine here
- Max 150 words
- If nothing new was learned, return the current content unchanged

Return only the updated content, no heading."""

MARK_ANSWERED_PROMPT = """A matchmaker AI has been talking to a user. Based on the current profile, which of these questions have clearly been answered?

Profile:
About: {about}
Context: {context}
Preferences: {preferences}
Matching: {matching}

Question keys to check:
{question_list}

Return a JSON array of keys that are clearly and explicitly answered in the profile.
Only include a key if the answer is present — do not include keys where the answer is vague or implied.
Example: ["relationship_goal", "career", "location"]
Return [] if nothing is clearly answered."""


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
        return field, current


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

    # Run 4 wiki upserts in parallel
    wiki_results = await asyncio.gather(
        _upsert_wiki_field(model, "about_me",    current["about_me"],    conversation, WIKI_ABOUT_ME_PROMPT),
        _upsert_wiki_field(model, "context",     current["context"],     conversation, WIKI_CONTEXT_PROMPT),
        _upsert_wiki_field(model, "preferences", current["preferences"], conversation, WIKI_PREFERENCES_PROMPT),
        _upsert_wiki_field(model, "matching",    current["matching"],    conversation, WIKI_MATCHING_PROMPT),
    )

    now = datetime.now(timezone.utc)
    wiki_updates = {f"wiki_{field}": text for field, text in wiki_results}
    for field, _ in wiki_results:
        wiki_updates[f"wiki_{field}_updated_at"] = now
        wiki_updates[f"wiki_{field}_session_id"] = body.session_id
    user_ref.update(wiki_updates)

    # Check which questions are now answered
    questions_snap = (
        user_ref.collection("questions")
        .where("answered", "==", False)
        .where("is_followup", "==", False)
        .stream()
    )
    pending = {d.id: d.to_dict() for d in questions_snap}

    if pending:
        updated_wiki = {f: t for _, (f, t) in zip(range(4), wiki_results)}
        question_list = "\n".join(
            f"- {v['key']}: {v['text']}" for v in pending.values()
        )
        mark_prompt = MARK_ANSWERED_PROMPT.format(
            about=wiki_updates.get("wiki_about_me", ""),
            context=wiki_updates.get("wiki_context", ""),
            preferences=wiki_updates.get("wiki_preferences", ""),
            matching=wiki_updates.get("wiki_matching", ""),
            question_list=question_list,
        )
        try:
            resp = await model.generate_content_async(
                mark_prompt,
                generation_config={"response_mime_type": "application/json"},
            )
            answered_keys: list[str] = json.loads(resp.text)
            if isinstance(answered_keys, list):
                now = datetime.now(timezone.utc)
                for doc_id, q in pending.items():
                    if q.get("key") in answered_keys:
                        user_ref.collection("questions").document(doc_id).update({
                            "answered": True,
                            "answered_at": now,
                        })
        except Exception:
            pass

    # Raw audit log
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


# ── Matching ──────────────────────────────────────────────────────────────────

_PII_FIELDS = frozenset({
    "display_name", "location_region", "employer", "email", "phone",
    "location_text", "location_lat", "location_lng",
})

_PROFILE_SKIP = frozenset({
    "id", "onboarding_complete", "matching_paused", "created_at", "updated_at",
    "voice_preference", "voice_accent", "voice_settings", "voice_preferences_updated_at",
    "agent_name",
})


def strip_pii(profile: dict) -> dict:
    """Remove personally identifying fields before sending a profile to the scoring LLM."""
    return {k: v for k, v in profile.items() if k not in _PII_FIELDS}


def _fmt_profile(profile: dict) -> str:
    skip = _PII_FIELDS | _PROFILE_SKIP
    lines = []
    for k, v in profile.items():
        if k in skip or not v:
            continue
        if isinstance(v, dict):
            lines.append(f"{k}: {json.dumps(v)}")
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
    """Return True if me and other pass the basic compatibility heuristics."""
    my_prefs = me.get("matching_prefs") or {}
    other_prefs = other.get("matching_prefs") or {}
    my_gender = (me.get("gender") or "").lower()
    other_gender = (other.get("gender") or "").lower()

    if not _interested_in(my_prefs, other_gender):
        return False
    if not _interested_in(other_prefs, my_gender):
        return False

    my_age = me.get("age")
    other_age = other.get("age")
    if my_age is not None and other_age is not None:
        a_min = my_prefs.get("age_min")
        a_max = my_prefs.get("age_max")
        b_min = other_prefs.get("age_min")
        b_max = other_prefs.get("age_max")
        if a_min is not None and a_max is not None and not (a_min <= other_age <= a_max):
            return False
        if b_min is not None and b_max is not None and not (b_min <= my_age <= b_max):
            return False

    return True


async def _score_pair(
    model: genai.GenerativeModel, me: dict, other: dict
) -> dict | None:
    """Call Gemini to score a candidate pair. Returns scoring dict or None on failure."""
    prompt = MATCHING_SCORING_PROMPT.format(
        profile_a=_fmt_profile(strip_pii(me)),
        profile_b=_fmt_profile(strip_pii(other)),
    )
    try:
        resp = await model.generate_content_async(
            prompt,
            generation_config={"response_mime_type": "application/json"},
        )
        result = json.loads(resp.text)
        if not isinstance(result.get("score"), (int, float)):
            return None
        return result
    except Exception:
        return None


@app.post("/run-matching")
async def run_matching(uid: str = Depends(verify_token)):
    user_ref = db.collection("users").document(uid)
    me = (user_ref.get().to_dict()) or {}
    if not me:
        raise HTTPException(status_code=404, detail="Profile not found")

    # Fetch onboarded users (limit to keep latency reasonable)
    candidates_snap = (
        db.collection("users")
        .where("onboarding_complete", "==", True)
        .limit(80)
        .stream()
    )
    candidates = [
        {**d.to_dict(), "id": d.id}
        for d in candidates_snap
        if d.id != uid
    ]

    filtered = [c for c in candidates if _is_heuristic_match(me, c)]

    # Fetch already-matched user IDs so we skip duplicates
    matched_ids: set[str] = set()
    for d in db.collection("matches").where("user_a", "==", uid).stream():
        matched_ids.add(d.to_dict().get("user_b", ""))
    for d in db.collection("matches").where("user_b", "==", uid).stream():
        matched_ids.add(d.to_dict().get("user_a", ""))

    to_score = [c for c in filtered if c["id"] not in matched_ids][:10]

    model = genai.GenerativeModel(TEXT_MODEL)
    now = datetime.now(timezone.utc)

    scorings = await asyncio.gather(*[_score_pair(model, me, c) for c in to_score])

    matches_ref = db.collection("matches")
    created = 0
    for candidate, scoring in zip(to_score, scorings):
        if scoring is None:
            continue
        score = float(scoring.get("score", 0.0))
        if score < 0.4:
            continue
        matches_ref.add({
            "user_a": uid,
            "user_b": candidate["id"],
            "score": round(score, 3),
            "rationale": scoring.get("rationale", ""),
            "summary_a": scoring.get("summary_a", ""),
            "summary_b": scoring.get("summary_b", ""),
            "status": "pending",
            "created_at": now.isoformat(),
            "updated_at": now.isoformat(),
        })
        created += 1

    return {"matches_created": created, "candidates_evaluated": len(to_score)}
