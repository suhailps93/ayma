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
import os
from datetime import datetime, timezone
from pathlib import Path
from contextlib import asynccontextmanager
from typing import Any

import asyncpg
import firebase_admin
import google.generativeai as genai
from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth
from pydantic import BaseModel

# ── Init ──────────────────────────────────────────────────────────────────────

FIREBASE_PROJECT_ID = os.environ.get("FIREBASE_PROJECT_ID", "ayma-ai")
if not firebase_admin._apps:
    firebase_admin.initialize_app(options={"projectId": FIREBASE_PROJECT_ID})

GOOGLE_API_KEY = os.environ["GOOGLE_API_KEY"]
LIVE_MODEL = os.environ.get("LIVE_MODEL", "gemini-3.1-flash-live-preview")
TEXT_MODEL = os.environ.get("TEXT_MODEL", "gemini-3-flash-preview")
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/ayma")

genai.configure(api_key=GOOGLE_API_KEY)

GEMINI_LIVE_WS = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Setup PostgreSQL connection pool
    app.state.pool = await asyncpg.create_pool(
        DATABASE_URL,
        min_size=1,
        max_size=10
    )
    yield
    # Close connection pool
    await app.state.pool.close()

app = FastAPI(title="ayma-bootstrap", lifespan=lifespan)
security = HTTPBearer()

# ── Auth ──────────────────────────────────────────────────────────────────────

def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    try:
        decoded = auth.verify_id_token(credentials.credentials)
        return decoded["uid"]
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid Firebase token")

# ── System prompt templates ───────────────────────────────────────────────────

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

PROFILE_COMPLETION_SKILL = """## Core Objective: Complete Match Profile Fast (Without Sounding Like A Form)

Your primary objective is to collect complete matching data across all profile fields as quickly as possible through natural conversation.

Rules:
- Do not run a rigid questionnaire.
- Extract facts from free-flow conversation whenever possible.
- Ask only 1 focused follow-up at a time to fill high-priority gaps.
- Prioritize unanswered required fields first, then preferences, then deeper context.
- If the user gives partial info, confirm briefly and continue.
- Keep momentum: every turn should either deepen rapport or close a missing profile field.
- For sensitive topics, ask gently and make it clear they can keep it private or skip."""

def _load_profile_schema() -> dict:
    try:
        base = Path(__file__).resolve().parents[2]  # repo root in dev; /app in container
        p = base / "docs" / "ayma_profile_questions.json"
        return json.loads(p.read_text())
    except Exception:
        return {"questions": [], "profile_storage_policy": {}}

PROFILE_SCHEMA = _load_profile_schema()
PROFILE_QUESTIONS = PROFILE_SCHEMA.get("questions", [])
PROFILE_FIELD_META = {q.get("id"): q for q in PROFILE_QUESTIONS if q.get("id")}
PUBLIC_PAYLOAD_ORDER = (
    PROFILE_SCHEMA.get("profile_storage_policy", {}).get("public_profile_payload_order", [])
)

def _build_system_prompt(
    profile: dict, skills: list[dict], pending_questions: list[dict]
) -> str:
    name = profile.get("display_name") or "User"
    agent_name = profile.get("agent_name") or "Ayma"

    parts = [
        MATCHMAKER_SKILL.replace("{agent_name}", agent_name),
        DEEP_RECALL_SKILL,
        TONE_MIRROR_SKILL,
        PROFILE_COMPLETION_SKILL,
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

    if profile.get("matching_prefs"):
        matching_prefs = {}
        try:
            matching_prefs = json.loads(profile["matching_prefs"]) if isinstance(profile["matching_prefs"], str) else profile["matching_prefs"]
        except Exception:
            pass
        if matching_prefs:
            parts.append(
                f"## Matching Preferences\n{json.dumps(matching_prefs, indent=2)}"
            )

    if profile.get("wiki_profile_structured"):
        parts.append(f"## Structured Match Profile\n{profile['wiki_profile_structured']}")

    profile_answers = {}
    if profile.get("profile_answers"):
        try:
            profile_answers = json.loads(profile["profile_answers"]) if isinstance(profile["profile_answers"], str) else profile["profile_answers"]
        except Exception:
            pass
    missing_required = [
        q["id"]
        for q in PROFILE_QUESTIONS
        if q.get("required") and q.get("id") and q["id"] not in profile_answers
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

    parts.append(
        f"\nThe user's name is {name}. "
        "When the conversation starts, greet them warmly as a friend. "
        "One short opening line, then ask something genuine."
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
                  "profile_field_visibility", "photo_order", "voice_settings"]:
        if field in res:
            try:
                res[field] = json.loads(res[field]) if isinstance(res[field], str) else res[field]
            except Exception:
                res[field] = {}
    return res

# ── Bootstrap ─────────────────────────────────────────────────────────────────

@app.post("/bootstrap")
async def bootstrap(uid: str = Depends(verify_token)):
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
            for q in PROFILE_QUESTIONS:
                qid = q.get("id")
                qtext = q.get("question_text", "")
                category = "deeper"
                if q.get("required"):
                    category = "required"
                elif q.get("section") in ("lifestyle_compatibility", "intent_and_readiness"):
                    category = "matching_prefs"
                
                to_insert.append((
                    uid, qid, qid, qtext, category, 99, False, None, False
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
    voice = profile.get("voice_preference") or "Charon"

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

# ── Consolidated Post-turn Synthesis ──────────────────────────────────────────

CONSOLIDATED_POST_TURN_PROMPT = """You are the backend brain of an AI matchmaking application called Ayma.
Your job is to process a conversation snippet and update the user's matchmaking profile, wiki memories, and checklist status.

Conversation:
{conversation}

---

## Part 1: Wiki Memories Update
You maintain 4 separate markdown fact lists for this user.
RULES:
- Only record facts the USER explicitly stated. Ignore what the AI/assistant said.
- Do NOT infer or extrapolate. Write exactly what was said, no elaboration.
- Max size: About Me (20 bullets), Life Context (10 bullets), Partner Preferences (20 bullets), Matching Specs (20 bullets).
- If nothing new was learned for a section, return the current list unchanged.

Current Wiki Blocks:
[About Me]:
{wiki_about_me}

[Life Context]:
{wiki_context}

[Partner Preferences]:
{wiki_preferences}

[Matching Specs]:
{wiki_matching}

---

## Part 2: Structured Field Extraction
Extract answers to the following structured profile questions if explicitly stated:
{field_catalog}

---

## Part 3: Answered Questions Checklist
Check if any of these unanswered questions have now been explicitly answered:
{unanswered_questions_list}

---

You MUST return a JSON object with this exact JSON schema:
{{
  "wiki_updates": {{
    "about_me": "updated about me markdown bullet list",
    "context": "updated life context markdown bullet list",
    "preferences": "updated preferences markdown bullet list",
    "matching": "updated matching specs markdown bullet list"
  }},
  "extracted_answers": [
    {{"id": "field_id", "value": <string|number|boolean|array|object>, "confidence": "high|medium"}}
  ],
  "sensitive_public_opt_in": ["field_id"],
  "public_summary": "1-3 sentences for a public profile summary, only if conversation has enough non-sensitive detail; else empty string",
  "answered_question_keys": ["key1", "key2"]
}}

Only include field IDs that are explicitly allowed. Do not output any prose, markdown wrapping outside the JSON, or comments. Just return raw JSON.
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
    q_order = [q.get("id") for q in PROFILE_QUESTIONS]

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
async def post_turn(body: PostTurnRequest, uid: str = Depends(verify_token)):
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
            f"- {q.get('id')}: {q.get('question_text')}" for q in PROFILE_QUESTIONS if q.get("id")
        )
        unanswered_questions_list = "\n".join(
            f"- {q['key']}: {q['text']}" for q in pending_questions
        )

        prompt = CONSOLIDATED_POST_TURN_PROMPT.format(
            conversation=conversation,
            wiki_about_me=profile.get("wiki_about_me") or "(empty)",
            wiki_context=profile.get("wiki_context") or "(empty)",
            wiki_preferences=profile.get("wiki_preferences") or "(empty)",
            wiki_matching=profile.get("wiki_matching") or "(empty)",
            field_catalog=field_catalog,
            unanswered_questions_list=unanswered_questions_list
        )

        # Call Gemini (Single consolidated extraction)
        model = genai.GenerativeModel(TEXT_MODEL)
        try:
            resp = await model.generate_content_async(
                prompt,
                generation_config={"response_mime_type": "application/json"}
            )
            payload = json.loads(resp.text)
        except Exception:
            payload = {}

        wiki_updates = payload.get("wiki_updates") or {}
        wiki_about_me = wiki_updates.get("about_me", profile.get("wiki_about_me") or "")
        wiki_context = wiki_updates.get("context", profile.get("wiki_context") or "")
        wiki_preferences = wiki_updates.get("preferences", profile.get("wiki_preferences") or "")
        wiki_matching = wiki_updates.get("matching", profile.get("wiki_matching") or "")

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

    return {"updated": True}

# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok"}

# ── Profile Endpoints ──────────────────────────────────────────────────────────

class ProfileUpdateBody(BaseModel):
    display_name: str | None = None
    age: int | None = None
    gender: str | None = None
    location_region: str | None = None
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
        if k in ("photo_order", "voice_settings", "matching_prefs"):
            v = json.dumps(v)
        set_clauses.append(f"{k} = ${idx}")
        args.append(v)
        idx += 1
    
    args.append(uid)
    query = f"UPDATE users SET {', '.join(set_clauses)}, updated_at = NOW() WHERE id = ${idx}"
    
    async with pool.acquire() as conn:
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
        media_rows = await conn.fetch("SELECT photo_url FROM user_media WHERE user_id = $1 ORDER BY created_at DESC LIMIT 24", userId)
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
        row = await conn.fetchrow("SELECT wiki_about_me, wiki_preferences, wiki_context, profile_public FROM users WHERE id = $1", uid)
        if not row:
            return {}
        profile = dict(row)
        
        media_rows = await conn.fetch("SELECT photo_url, caption, created_at FROM user_media WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20", uid)
        
        media_lines = []
        for mr in media_rows:
            date_str = mr["created_at"].strftime("%Y-%m-%d")
            line = f"- [{date_str}]({mr['photo_url']})"
            if mr["caption"]:
                line += f"\n  {mr['caption']}"
            media_lines.append(line)
        
        return {
            "about_me": profile.get("wiki_about_me") or "",
            "preferences": profile.get("wiki_preferences") or "",
            "context": profile.get("wiki_context") or "",
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
        rows = await conn.fetch("SELECT id, user_id, type, title, body, meta, read, created_at FROM notifications WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50", uid)
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
        
    sql += " LIMIT 50"
    
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

# ── Direct Messaging Endpoints ─────────────────────────────────────────────────

class MessageBody(BaseModel):
    target_user_id: str
    text: str

@app.post("/messages")
async def send_direct_message(body: MessageBody, uid: str = Depends(verify_token)):
    pool = app.state.pool
    async with pool.acquire() as conn:
        # Save message
        await conn.execute("INSERT INTO messages (from_user_id, to_user_id, text) VALUES ($1, $2, $3)", uid, body.target_user_id, body.text)
        
        # Save notification
        me = await conn.fetchrow("SELECT display_name FROM users WHERE id = $1", uid)
        my_name = me["display_name"] if me and me["display_name"] else "Someone"
        body_text = f"{my_name} sent you a message."
        meta = json.dumps({"from_user_id": uid})
        
        await conn.execute("""
            INSERT INTO notifications (user_id, type, title, body, meta, read)
            VALUES ($1, 'agent_update', 'New message', $2, $3, FALSE)
        """, body.target_user_id, body_text, meta)
        
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
            LIMIT 200
        """, uid, other_user_id)
        
        msgs = []
        for r in rows:
            m = dict(r)
            m["created_at"] = m["created_at"].isoformat()
            m["id"] = str(m["id"])
            msgs.append(m)
        return msgs

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
    try:
        result = await asyncio.to_thread(
            genai.embed_content,
            model="models/text-embedding-004",
            content=text,
            task_type="semantic_similarity"
        )
        return result.get('embedding')
    except Exception as e:
        print(f"Error generating embedding: {e}")
        return None

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
    
    my_gender = (me.get("gender") or "").lower().strip()
    other_gender = (other.get("gender") or "").lower().strip()
    
    # 1. Gender check
    if not _interested_in(my_prefs, other_gender):
        return False
    if not _interested_in(other_prefs, my_gender):
        return False
        
    # 2. Age check
    my_age = me.get("age")
    other_age = other.get("age")
    if my_age is None or other_age is None:
        return False
        
    my_min = my_prefs.get("age_min")
    my_max = my_prefs.get("age_max")
    if my_min is not None and other_age < int(my_min):
        return False
    if my_max is not None and other_age > int(my_max):
        return False
        
    other_min = other_prefs.get("age_min")
    other_max = other_prefs.get("age_max")
    if other_min is not None and my_age < int(other_min):
        return False
    if other_max is not None and my_age > int(other_max):
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

async def _run_vibe_check(match_id: int, uid_a: str, uid_b: str, conn, model: genai.GenerativeModel) -> dict:
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
        sim_resp = await model.generate_content_async(sim_prompt)
        conversation = sim_resp.text.strip()
    except Exception:
        conversation = "(simulation unavailable)"
        
    # Rate chemistry and compatibility
    score_prompt = VIBE_SCORE_PROMPT.format(
        profile_a=fmt_a,
        profile_b=fmt_b,
        conversation=conversation
    )
    try:
        score_resp = await model.generate_content_async(
            score_prompt,
            generation_config={"response_mime_type": "application/json"}
        )
        result = json.loads(score_resp.text)
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
async def run_matching(uid: str = Depends(verify_token)):
    pool = app.state.pool
    model = genai.GenerativeModel(TEXT_MODEL)
    
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
            candidate_rows = await conn.fetch("""
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
                LIMIT 100
            """, uid, vector_str)
        else:
            candidate_rows = await conn.fetch("""
                SELECT * FROM users
                WHERE onboarding_complete = TRUE
                  AND matching_paused = FALSE
                  AND id != $1
                  AND id NOT IN (
                      SELECT user_a FROM matches WHERE user_b = $1
                      UNION
                      SELECT user_b FROM matches WHERE user_a = $1
                  )
                LIMIT 100
            """, uid)
            
        candidates = [_parse_row(r) for r in candidate_rows]
        filtered = [c for c in candidates if _is_heuristic_match(me, c)]
        
        to_score = filtered[:15]
        if not to_score:
            return {"matches_created": 0, "candidates_evaluated": 0}
            
        scorings = await asyncio.gather(*[_score_pair(model, me, c) for c in to_score])
        
        scored_pairs = [
            (c, s) for c, s in zip(to_score, scorings)
            if s is not None and float(s.get("score", 0.0)) >= 0.4
        ]
        scored_pairs.sort(key=lambda x: float(x[1].get("score", 0.0)), reverse=True)
        
        created = 0
        vibe_threshold = 0.65
        vibe_candidates = [p for p in scored_pairs if float(p[1].get("score", 0.0)) >= vibe_threshold][:5]
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
                
                final_score = round(score * 0.7 + (synergy_score / 100) * 0.3, 3)
                
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
            
        return {"matches_created": created, "candidates_evaluated": len(to_score)}

class VibeCheckRequest(BaseModel):
    match_id: int

@app.post("/vibe-check")
async def vibe_check(body: VibeCheckRequest, uid: str = Depends(verify_token)):
    pool = app.state.pool
    model = genai.GenerativeModel(TEXT_MODEL)
    
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
        result = await _run_vibe_check(body.match_id, uid, other_uid, conn, model)
        synergy_score = result["synergy_score"]
        synergy_summary = result["synergy_summary"]
        
        compat_score = float(match.get("score") or 0.0)
        final_score = round(compat_score * 0.7 + (synergy_score / 100) * 0.3, 3)
        
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
