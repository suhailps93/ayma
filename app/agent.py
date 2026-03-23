# ruff: noqa
import logging
import os
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import google.auth
import vertexai

from dotenv import load_dotenv
from google.adk.agents import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.adk.agents.readonly_context import ReadonlyContext
from google.adk.tools import google_search
from google.adk.tools.tool_context import ToolContext
from google.genai import types

load_dotenv()

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

_, project_id = google.auth.default()
os.environ.setdefault("GOOGLE_CLOUD_PROJECT", project_id)
os.environ.setdefault("GOOGLE_CLOUD_LOCATION", "us-central1")
os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "True"

vertexai.init(
    project=os.environ["GOOGLE_CLOUD_PROJECT"],
    location=os.environ["GOOGLE_CLOUD_LOCATION"],
)

# Available Gemini Live voices
AVAILABLE_VOICES = ["Charon", "Puck", "Kore", "Fenrir", "Aoede"]
DEFAULT_VOICE = "Charon"


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

def get_current_time(timezone: str = "UTC") -> dict:
    """Return the current date and time in a given IANA timezone.

    Args:
        timezone: IANA timezone string, e.g. "Asia/Dubai", "America/New_York",
                  "Europe/London". Defaults to "UTC" if unknown.

    Returns:
        A dict with keys: datetime_local, timezone, utc_offset.
    """
    try:
        tz = ZoneInfo(timezone)
    except (ZoneInfoNotFoundError, Exception):
        tz = ZoneInfo("UTC")
        timezone = "UTC"

    now = datetime.now(tz)
    return {
        "datetime_local": now.strftime("%A, %d %B %Y %H:%M"),
        "timezone": timezone,
        "utc_offset": now.strftime("%z"),
    }


async def submit_feedback(
    issue: str,
    feedback_type: str,
    tool_context: ToolContext,
) -> dict:
    """Capture user feedback about the conversation or app.

    Use this when the user expresses dissatisfaction or a preference about
    how you behave (e.g. "you're too formal", "stop being so flirty") OR
    reports a bug or feature request about the app.

    Args:
        issue: Clear description of the feedback in the user's own words.
        feedback_type: One of:
            - "personal_preference" — how the user wants YOU to behave
              differently. Will be saved to their profile as a custom instruction.
            - "bug" — something in the app is broken.
            - "feature_request" — the user wants a new feature.
            - "ux" — confusing or frustrating user experience.

    Returns:
        A confirmation dict.
    """
    user_id = tool_context.user_id

    try:
        from supabase import create_client
        supabase = create_client(
            os.environ["SUPABASE_URL"],
            os.environ["SUPABASE_SERVICE_ROLE_KEY"],
        )

        if feedback_type == "personal_preference":
            # Translate preference into a concise instruction and append to user_skills
            from langchain_google_genai import ChatGoogleGenerativeAI
            from langchain_core.messages import SystemMessage

            llm = ChatGoogleGenerativeAI(model="gemini-2.5-flash", temperature=0.3)
            result = await llm.ainvoke([
                SystemMessage(content=(
                    "Convert this user preference into a single, concise instruction "
                    "for an AI matchmaker to follow. Max 2 sentences. "
                    "Start with an imperative verb. No explanation."
                )),
                {"role": "user", "content": issue},
            ])
            instruction = result.content.strip()

            # Append to user_skills (create row if not exists)
            existing = supabase.table("user_skills").select("skill_text").eq(
                "user_id", user_id
            ).eq("skill_type", "preference").execute()

            if existing.data:
                old = existing.data[0]["skill_text"]
                new_text = f"{old}\n{instruction}"
                supabase.table("user_skills").update({"skill_text": new_text}).eq(
                    "user_id", user_id
                ).eq("skill_type", "preference").execute()
            else:
                supabase.table("user_skills").insert({
                    "user_id": user_id,
                    "skill_type": "preference",
                    "skill_text": instruction,
                }).execute()

            logger.info(f"[feedback] saved personal_preference for {user_id}: {instruction}")
            return {"saved": True, "type": "personal_preference", "instruction": instruction}

        else:
            # Universal app feedback → app_feedback table
            category = feedback_type if feedback_type in ("bug", "feature_request", "ux") else "other"
            supabase.table("app_feedback").insert({
                "user_id": user_id,
                "feedback": issue,
                "category": category,
            }).execute()
            logger.info(f"[feedback] saved {category} feedback from {user_id}")
            return {"saved": True, "type": category}

    except Exception as e:
        logger.error(f"[feedback] error: {e}")
        return {"saved": False, "error": str(e)}


# ---------------------------------------------------------------------------
# Instruction provider
# ---------------------------------------------------------------------------

async def _build_instruction(context: ReadonlyContext) -> str:
    """
    InstructionProvider — called by ADK at the start of each session.

    Builds the full Ayma system prompt from the user's profile, skills, and memory.
    Always returns a valid instruction — falls back to full default persona if DB fails.
    """
    user_id = context.user_id
    logger.info(f"[instruction] building for user_id={user_id!r}")

    # Always load system skills — if this fails we have bigger problems
    from app.skills import load_system_skills, load_user_skills
    system_skills = load_system_skills().replace("{agent_name}", "Ayma")

    voice_modifier = (
        "You are in a live voice conversation. Rules:\n"
        "- Keep every response to 1-3 sentences. Never longer.\n"
        "- No markdown, bullet points, or lists. Speak naturally.\n"
        "- If you need to think, say 'let me think about that' — don't go silent.\n"
        "- Match the user's energy and pace."
    )

    if not user_id:
        logger.warning("[instruction] no user_id — using default persona")
        return "\n\n".join([system_skills, voice_modifier])

    try:
        from supabase import create_client
        supabase = create_client(
            os.environ["SUPABASE_URL"],
            os.environ["SUPABASE_SERVICE_ROLE_KEY"],
        )

        result = supabase.table("user_profiles").select(
            "agent_name, profile_private, display_name, age, gender, location_region, matching_prefs"
        ).eq("id", user_id).maybe_single().execute()

        profile = result.data or {}
        agent_name = profile.get("agent_name") or "Ayma"
        profile_private = profile.get("profile_private") or ""
        display_name = profile.get("display_name") or ""
        age = profile.get("age")
        gender = profile.get("gender") or ""
        location = profile.get("location_region") or ""
        matching_prefs = profile.get("matching_prefs") or {}

        # Replace agent name placeholder
        system_skills = system_skills.replace("Ayma", agent_name)

        user_skills = await load_user_skills(user_id, supabase)

        from mem0 import MemoryClient
        mem0 = MemoryClient(api_key=os.environ["MEM0_API_KEY"])
        facts_raw = mem0.get_all(user_id=user_id)
        items = facts_raw if isinstance(facts_raw, list) else facts_raw.get("results", [])
        mem0_facts = "\n".join(f"- {r['memory']}" for r in items) if items else ""

        # Build user context block (demographics + location)
        user_context_lines = []
        if display_name:
            user_context_lines.append(f"Name: {display_name}")
        if age:
            user_context_lines.append(f"Age: {age}")
        if gender:
            user_context_lines.append(f"Gender: {gender}")
        if location:
            user_context_lines.append(
                f"Location: {location} — use this for local recommendations, time zone, "
                f"and nearby events when relevant. When asked about current time, use "
                f"get_current_time with the appropriate IANA timezone for this location."
            )
        if matching_prefs:
            if matching_prefs.get("interested_in"):
                user_context_lines.append(f"Interested in: {', '.join(matching_prefs['interested_in'])}")
            age_min = matching_prefs.get("age_min")
            age_max = matching_prefs.get("age_max")
            if age_min and age_max:
                user_context_lines.append(f"Preferred age range: {age_min}–{age_max}")

        sections = [system_skills]
        if user_skills:
            sections.append(f"## Additional Instructions\n{user_skills}")
        if user_context_lines:
            sections.append("## About this person\n" + "\n".join(user_context_lines))
        if profile_private:
            sections.append(
                f"## What you know about this person (private — never share directly)\n{profile_private}"
            )
        if mem0_facts:
            sections.append(f"## Facts about this person\n{mem0_facts}")
        sections.append(voice_modifier)

        instruction = "\n\n".join(s for s in sections if s.strip())
        logger.info(f"[instruction] built {len(instruction)} chars for user {user_id}")
        return instruction

    except Exception as e:
        logger.warning(f"[instruction] DB error for {user_id}: {e} — using default persona")
        return "\n\n".join([system_skills, voice_modifier])


# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

root_agent = Agent(
    name="ayma_voice_agent",
    model=Gemini(
        model="gemini-live-2.5-flash-native-audio",
        retry_options=types.HttpRetryOptions(attempts=3),
    ),
    instruction=_build_instruction,
    tools=[
        google_search,
        get_current_time,
        submit_feedback,
    ],
)

app = App(root_agent=root_agent, name="app")
