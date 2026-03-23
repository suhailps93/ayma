# ruff: noqa
import os
import google.auth
import vertexai

from dotenv import load_dotenv
from google.adk.agents import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.adk.agents.readonly_context import ReadonlyContext
from google.genai import types

load_dotenv()

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


async def _build_voice_instruction(context: ReadonlyContext) -> str:
    """
    InstructionProvider — called by ADK at the start of each voice session.

    Fetches the user's profile and builds a personalized system prompt.
    Falls back to a generic prompt gracefully if anything fails.
    """
    user_id = context.user_id

    try:
        from supabase import create_client
        from app.skills import load_system_skills, load_user_skills

        supabase = create_client(
            os.environ["SUPABASE_URL"],
            os.environ["SUPABASE_SERVICE_ROLE_KEY"],
        )

        # Fetch profile
        result = supabase.table("user_profiles").select(
            "agent_name, profile_private, profile_public_locked"
        ).eq("id", user_id).single().execute()
        profile = result.data or {}

        # Fetch Mem0 facts
        from mem0 import MemoryClient
        mem0 = MemoryClient(api_key=os.environ["MEM0_API_KEY"])
        facts_raw = mem0.get_all(user_id=user_id)
        items = facts_raw if isinstance(facts_raw, list) else facts_raw.get("results", [])
        mem0_facts = "\n".join(f"- {r['memory']}" for r in items) if items else ""

        agent_name = profile.get("agent_name", "Ayma")
        profile_private = profile.get("profile_private", "")
        system_skills = load_system_skills()
        user_skills = await load_user_skills(user_id, supabase)

        sections = [
            f"You are {agent_name}, a warm and perceptive personal AI companion.",
            system_skills,
        ]
        if user_skills:
            sections.append(f"## Additional Instructions\n{user_skills}")
        if profile_private:
            sections.append(
                f"## What you know about this person (private — never share directly)\n{profile_private}"
            )
        if mem0_facts:
            sections.append(f"## Facts about this person\n{mem0_facts}")

        # Voice modifier — always appended for voice sessions
        sections.append(
            "You are in a live voice conversation. Rules:\n"
            "- Keep every response to 1-3 sentences. Never longer.\n"
            "- No markdown, bullet points, or lists. Speak naturally.\n"
            "- If you need to think, say 'let me think about that' — don't go silent.\n"
            "- Match the user's energy and pace."
        )

        return "\n\n".join(s for s in sections if s.strip())

    except Exception:
        # Always fall back gracefully — voice session must not fail to start
        return (
            "You are Ayma, a warm personal AI companion. "
            "Keep responses to 1-3 sentences. Speak naturally."
        )


async def _get_voice_config(user_id: str) -> types.SpeechConfig:
    """Fetch the user's preferred voice from DB, fall back to default."""
    try:
        from supabase import create_client
        supabase = create_client(
            os.environ["SUPABASE_URL"],
            os.environ["SUPABASE_SERVICE_ROLE_KEY"],
        )
        result = supabase.table("user_profiles").select(
            "voice_preference"
        ).eq("id", user_id).single().execute()
        voice = result.data.get("voice_preference", DEFAULT_VOICE)
        if voice not in AVAILABLE_VOICES:
            voice = DEFAULT_VOICE
    except Exception:
        voice = DEFAULT_VOICE

    return types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice)
        )
    )


root_agent = Agent(
    name="ayma_voice_agent",
    model=Gemini(
        model="gemini-live-2.5-flash-native-audio",
        retry_options=types.HttpRetryOptions(attempts=3),
    ),
    # InstructionProvider: called per-session, returns personalized prompt
    instruction=_build_voice_instruction,
)

app = App(root_agent=root_agent, name="app")
