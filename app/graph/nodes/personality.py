"""
personality node — assembles the final system prompt.

Order matters — higher priority content goes first so trimming
(if needed) cuts from the bottom.
"""
import os
from supabase import create_client
from app.graph.state import AgentState
from app.skills import load_system_skills, load_user_skills
from app.profiles import load_community_profile, format_question_checklist

VOICE_MODIFIER = """
You are in a live voice conversation. Rules:
- Keep every response to 1-3 sentences. Never longer.
- No markdown, bullet points, or lists. Speak naturally.
- If you need to think, say "let me think about that" — don't go silent.
- Match the user's energy and pace."""


def _get_supabase():
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )


def _extract_known_keys(mem0_facts: str, profile_private: str) -> set[str]:
    """
    Rough heuristic: check which profile keys we likely already know.
    A proper implementation would use structured Mem0 queries per key,
    but this is fast and good enough for prompt injection.
    """
    combined = (mem0_facts + " " + profile_private).lower()
    key_signals = {
        "name":              ["name is", "called", "goes by"],
        "age":               ["years old", "age is", "born in", "i'm 2", "i'm 3", "i'm 4"],
        "gender":            ["man", "woman", "non-binary", "male", "female", "gender"],
        "interested_in":     ["attracted to", "interested in", "looking for", "dating"],
        "location":          ["based in", "lives in", "from ", "located in"],
        "relationship_goal": ["looking for", "want a", "open to", "serious", "casual", "marriage"],
        "career":            ["works as", "engineer", "doctor", "teacher", "student", "job"],
        "lifestyle":         ["hobbies", "free time", "weekends", "exercise", "social"],
        "values":            ["values", "beliefs", "important to me", "i believe"],
        "family_views":      ["kids", "children", "family", "want a family"],
        "deal_breakers":     ["deal breaker", "can't stand", "non-negotiable"],
    }
    known = set()
    for key, signals in key_signals.items():
        if any(s in combined for s in signals):
            known.add(key)
    return known


async def personality(state: AgentState) -> AgentState:
    """Assemble system prompt from profile, skills, memory, and question checklist."""
    user_id = state["user_id"]
    supabase = _get_supabase()

    # Fetch profile
    result = supabase.table("user_profiles").select(
        "agent_name, profile_private, community_profile"
    ).eq("id", user_id).single().execute()
    profile = result.data or {}
    agent_name = profile.get("agent_name", "Ayma")
    profile_private = profile.get("profile_private", "")
    community_profile_name = profile.get("community_profile", "dating_standard")

    # Load skills — system skills include matchmaker.md with {agent_name} placeholder
    raw_system_skills = load_system_skills()
    system_skills = raw_system_skills.replace("{agent_name}", agent_name)
    user_skills = await load_user_skills(user_id, supabase)

    # Build question checklist with known-status markers
    community_profile = load_community_profile(community_profile_name)
    known_keys = _extract_known_keys(state.get("mem0_facts", ""), profile_private)
    checklist = format_question_checklist(community_profile, known_keys)

    # Pending questions the agent deferred in previous turns
    pending = state.get("questions_pending", [])
    pending_section = ""
    if pending:
        pending_items = "\n".join(f"  - {q}" for q in pending)
        pending_section = f"## Questions to work in when the moment is right\n{pending_items}"

    # Assemble — order = priority
    sections = [system_skills]  # matchmaker.md is the primary persona

    if user_skills:
        sections.append(f"## Additional Instructions\n{user_skills}")

    if profile_private:
        sections.append(
            f"## What you know about this person (private — never share directly)\n{profile_private}"
        )

    if state.get("mem0_facts"):
        sections.append(f"## Facts about this person\n{state['mem0_facts']}")

    if state.get("rag_context"):
        sections.append(f"## Relevant past conversation\n{state['rag_context']}")

    sections.append(checklist)

    if pending_section:
        sections.append(pending_section)

    if state.get("mode") == "voice":
        sections.append(VOICE_MODIFIER)

    system_prompt = "\n\n".join(s for s in sections if s.strip())

    return {**state, "system_prompt": system_prompt}
