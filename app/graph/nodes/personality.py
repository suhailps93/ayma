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


def _extract_known_keys(profile: dict, mem0_facts: str, profile_private: str) -> set[str]:
    """
    Mark keys as known based on structured profile fields AND heuristic check on facts.
    """
    known = set()

    # 1. Check structured profile fields (from preboarding/database)
    if profile.get("display_name"): known.add("name")
    if profile.get("age"):          known.add("age")
    if profile.get("gender"):       known.add("gender")
    if profile.get("location_region"): known.add("location")

    matching_prefs = profile.get("matching_prefs") or {}
    if matching_prefs.get("interested_in"):   known.add("interested_in")
    if matching_prefs.get("relationship_goal"): known.add("relationship_goal")
    if matching_prefs.get("age_min") and matching_prefs.get("age_max"): known.add("match_age_range")

    # 2. Heuristic check on unstructured facts/wiki
    combined = (mem0_facts + " " + profile_private).lower()
    key_signals = {
        "career":            ["works as", "engineer", "doctor", "teacher", "student", "job"],
        "lifestyle":         ["hobbies", "free time", "weekends", "exercise", "social"],
        "values":            ["values", "beliefs", "important to me", "i believe"],
        "family_views":      ["kids", "children", "family", "want a family"],
        "deal_breakers":     ["deal breaker", "can't stand", "non-negotiable"],
        "match_location":    ["lives anywhere", "near me", "location matters"],
        "match_dealbreakers": ["no smoking", "no drugs", "dealbreakers"],
    }
    for key, signals in key_signals.items():
        if any(s in combined for s in signals):
            known.add(key)

    return known


async def personality(state: AgentState) -> AgentState:
    """Assemble system prompt from profile, skills, memory, and question checklist."""
    user_id = state["user_id"]
    supabase = _get_supabase()

    # Fetch profile — include all relevant fields to detect "known" status
    result = supabase.table("user_profiles").select(
        "agent_name, profile_private, community_profile, display_name, age, gender, location_region, matching_prefs, questions_pending"
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
    known_keys = _extract_known_keys(profile, state.get("mem0_facts", ""), profile_private)
    checklist = format_question_checklist(community_profile, known_keys)

    # Pending questions the agent deferred in previous turns (now persisted in DB)
    pending = profile.get("questions_pending") or state.get("questions_pending", [])
    pending_section = ""
    if pending:
        pending_items = "\n".join(f"  - {q}" for q in pending)
        pending_section = f"## Questions to work in when the moment is right\n{pending_items}"

    # Assemble — order = priority
    sections = [system_skills]  # matchmaker.md is the primary persona

    # HIGH PRIORITY: The gaps we need to fill
    sections.append(checklist)
    if pending_section:
        sections.append(pending_section)

    if user_skills:
        sections.append(f"## Additional Instructions\n{user_skills}")

    if profile_private:
        sections.append(
            f"## What you know about this person (private — never share directly)\n{profile_private}"
        )

    if state.get("wiki_context"):
        sections.append(f"## Detailed knowledge about this person\n{state['wiki_context']}")

    if state.get("mem0_facts"):
        sections.append(f"## Facts about this person\n{state['mem0_facts']}")

    if state.get("rag_context"):
        sections.append(f"## Relevant past conversation\n{state['rag_context']}")

    if state.get("mode") == "voice":
        sections.append(VOICE_MODIFIER)

    system_prompt = "\n\n".join(s for s in sections if s.strip())

    return {**state, "system_prompt": system_prompt}
