"""
/internal/update-profile handler

Called by Cloud Tasks after every session.
Rewrites all three profile tiers using Gemini Flash.

Tier 1 (public):
  - if profile_public_locked = false → auto-apply (direct write)
  - if profile_public_locked = true  → write to profile_suggestions instead

Tier 2 (private):   always auto-apply, no user approval
Tier 3 (ai_obs):    always auto-apply, never exposed to client
"""
import asyncio
import logging
import os
from mem0 import MemoryClient
from supabase import create_client
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.messages import HumanMessage

from app.model_config import FAST_MODEL
from app.internal.notifications import create_notification

logger = logging.getLogger(__name__)

PUBLIC_PROFILE_PROMPT = """You are writing a public profile for a person based on everything you know about them.
Write in third person, warm and specific. 2-4 short paragraphs. No bullet points.
Make it feel like a genuine person wrote it, not a form.

## Everything known about this person (from memory)
{mem0_facts}

## Topics to exclude from the public profile (user-specified)
{exclusions}

Current public profile (improve it, do not start from scratch unless empty):
{current_public}

Write the updated public profile now. Output only the profile text."""

PRIVATE_NOTES_PROMPT = """You are maintaining private context notes about a person that help their AI companion
respond to them better. Include: emotional state, goals, sensitivities, relationship context, health,
anything personal that affects how the AI should talk to them. Be honest and specific.
Never share these notes with anyone.

## Current memory facts
{mem0_facts}

## Current private notes (update, don't just repeat)
{current_private}

Write updated private notes now. Output only the notes."""

AI_OBSERVATIONS_PROMPT = """You are an internal analytical system. Write sharp, honest observations about this person
that they may not be aware of. Be specific and evidence-based. This is never shown to the user.
It is used only to improve matching and agent calibration.

## Memory facts
{mem0_facts}

## Previous observations (update, don't just repeat)
{current_observations}

Write updated observations now. Output only the observations."""


def _get_llm():
    return ChatGoogleGenerativeAI(
        model=FAST_MODEL,
        temperature=0.4,
    )


async def _rewrite(llm, prompt: str) -> str:
    result = await llm.ainvoke([HumanMessage(content=prompt)])
    raw = result.content
    if isinstance(raw, list):
        raw = " ".join(
            block.get("text", "") if isinstance(block, dict) else str(block)
            for block in raw
        )
    return str(raw).strip()


async def handle_profile_update(user_id: str) -> None:
    supabase = create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )
    mem0 = MemoryClient(api_key=os.environ["MEM0_API_KEY"])
    llm = _get_llm()

    # Fetch current profile + exclusions
    profile_res = supabase.table("user_profiles").select(
        "profile_public, profile_private, profile_ai_observations, profile_public_locked"
    ).eq("id", user_id).maybe_single().execute()
    profile = profile_res.data or {}

    excl_res = supabase.table("profile_exclusions").select("topic").eq("user_id", user_id).execute()
    exclusions = ", ".join(r["topic"] for r in (excl_res.data or [])) or "none"

    # Fetch Mem0 facts (blocking SDK — run in thread to avoid blocking the event loop)
    try:
        facts_raw = await asyncio.to_thread(mem0.get_all, user_id=user_id)
        items = facts_raw if isinstance(facts_raw, list) else facts_raw.get("results", [])
        mem0_facts = "\n".join(f"- {r['memory']}" for r in items) if items else "No facts yet."
    except Exception as e:
        logger.warning("[profile_update] mem0.get_all failed for %s: %s", user_id, e)
        mem0_facts = "No facts yet."
    logger.info("[profile_update] starting rewrite for %s — mem0_facts: %d chars", user_id, len(mem0_facts))

    # Rewrite all three tiers in parallel
    public_text, private_text, obs_text = await asyncio.gather(
        _rewrite(llm, PUBLIC_PROFILE_PROMPT.format(
            mem0_facts=mem0_facts,
            exclusions=exclusions,
            current_public=profile.get("profile_public", ""),
        )),
        _rewrite(llm, PRIVATE_NOTES_PROMPT.format(
            mem0_facts=mem0_facts,
            current_private=profile.get("profile_private", ""),
        )),
        _rewrite(llm, AI_OBSERVATIONS_PROMPT.format(
            mem0_facts=mem0_facts,
            current_observations=profile.get("profile_ai_observations", ""),
        )),
    )

    logger.info("[profile_update] rewrites done for %s — public=%d private=%d obs=%d chars",
                user_id, len(public_text), len(private_text), len(obs_text))

    # Write private + observations directly (always auto-applied)
    supabase.table("user_profiles").update({
        "profile_private": private_text,
        "profile_ai_observations": obs_text,
    }).eq("id", user_id).execute()

    # Write public based on lock state
    if not profile.get("profile_public_locked", False):
        supabase.table("user_profiles").update({
            "profile_public": public_text,
        }).eq("id", user_id).execute()
        logger.info("[profile_update] public profile written for %s", user_id)
    else:
        supabase.table("profile_suggestions").insert({
            "user_id": user_id,
            "tier": "public",
            "draft": public_text,
            "status": "pending",
        }).execute()
        try:
            create_notification(
                user_id,
                notif_type="profile_suggestion",
                title="Profile suggestion ready",
                body="Ayma drafted a new public profile suggestion for you to review.",
                meta={"tier": "public"},
            )
        except Exception:
            pass

    try:
        from app.internal.match_generation import handle_match_generation
        await handle_match_generation(user_id)
    except Exception:
        pass
