"""
/internal/wiki-update handler

Updates per-user wiki pages after each conversation turn.
Runs three page updates in parallel: about_me.md, preferences.md, context.md

Called by Cloud Tasks (fire-and-forget) from the memorize node.
media.md is updated separately by media_process.py on photo upload.
"""
import asyncio
import logging

from langchain_core.messages import HumanMessage
from langchain_google_genai import ChatGoogleGenerativeAI

from app.model_config import FAST_MODEL
from app.wiki import read_wiki_page, write_wiki_page

logger = logging.getLogger(__name__)

ABOUT_ME_PROMPT = """You maintain a wiki page capturing a person's "Inner Persona" — \
their personality, voice, communication style, core temperament, and the "vibe" \
they project. 

Ignore hard facts like career or age (those are tracked elsewhere). Focus on:
- How they speak (direct, playful, reserved, etc.)
- Their sense of humor and energy
- Their core temperament and worldview
- How they relate to others emotionally

## Last conversation turn
{exchange}

## Current page
{current}

## Task
Update the page based ONLY on the last conversation turn. 
1. Preserve the 1st-person, natural narrative style.
2. Focus on "who" they are, not "what" they have.
3. NEVER invent details or hallucinate.
4. If nothing new about their personality was learned, return the current page exactly.

Write in the first person. Max 250 words.
Output ONLY the updated persona content."""

PREFERENCES_PROMPT = """You maintain a wiki page capturing what a person wants in a \
romantic partner — attraction, values alignment, dealbreakers, relationship goals, \
what they've said they need.

## Last conversation turn
{exchange}

## Current page
{current}

## Task
Update the page based ONLY on the last conversation turn.
1. Preserve all existing accurate information.
2. Add new preferences, dealbreakers, or goals revealed in the latest turn.
3. Correct any information that has been updated by the user.
4. NEVER invent details or hallucinate information not present in the conversation or the current page.
5. If nothing new was learned, return the current page exactly.

Write in a specific and honest way. Max 200 words.
Output ONLY the updated page content."""

CONTEXT_PROMPT = """You maintain a wiki page capturing a person's current life context — \
emotional state, recent events, what they're going through, short-term goals, \
what's on their mind right now.

## Last conversation turn
{exchange}

## Current page
{current}

## Task
Update the page based ONLY on the last conversation turn.
1. Refresh stale context with new information.
2. Preserve ongoing context that hasn't changed.
3. NEVER invent details or hallucinate information not present in the conversation or the current page.
4. If nothing new was learned, return the current page exactly.

Write natural and relevant context. Max 200 words.
Output ONLY the updated page content."""

MATCHING_PROFILE_PROMPT = """You maintain a "Matching Gold Record" — a structured summary \
of the key data points required for a dating matchmaker. 

Focus on these pillars:
- Identity: Name, Age, Gender, Location
- Intent: Relationship goals, intensity of search
- Foundation: Career, Lifestyle, Core Values, Religion
- Relational: Love languages, conflict style, humor, social energy
- The "Hook": What makes them unique or magnetic

## Last conversation turn
{exchange}

## Current page
{current}

## Task
Update the profile based ONLY on the latest conversation. 
1. Use a clear, bulleted or sectioned format.
2. Update existing facts with more detail or corrections.
3. Only add new data if the user explicitly shared it.
4. ABSOLUTELY NO HALLUCINATIONS. If you don't know a field, leave it as "(unknown)".
5. Maintain a high-signal, objective tone.

Output ONLY the updated matching profile content."""

_PAGES = [
    ("about_me.md", ABOUT_ME_PROMPT),
    ("preferences.md", PREFERENCES_PROMPT),
    ("context.md", CONTEXT_PROMPT),
    ("matching_profile.md", MATCHING_PROFILE_PROMPT),
]


def _llm() -> ChatGoogleGenerativeAI:
    return ChatGoogleGenerativeAI(model=FAST_MODEL, temperature=0.3)


async def _update_page(
    llm: ChatGoogleGenerativeAI,
    user_id: str,
    page: str,
    prompt_template: str,
    exchange: str,
) -> None:
    current = read_wiki_page(user_id, page)
    filled = prompt_template.format(
        exchange=exchange,
        current=current or "(empty — write the first entry based on the conversation above)",
    )
    result = await llm.ainvoke([HumanMessage(content=filled)])
    raw = result.content
    # LangChain may return a list of content blocks (Gemini) — extract text
    if isinstance(raw, list):
        raw = " ".join(
            block.get("text", "") if isinstance(block, dict) else str(block)
            for block in raw
        )
    updated = str(raw).strip()
    if updated:
        write_wiki_page(user_id, page, updated)


async def handle_wiki_update(user_id: str, messages: list[dict]) -> None:
    """Update wiki pages from the last conversation turn."""
    if not messages:
        return
    exchange = "\n".join(
        f"{'User' if m['role'] in ('human', 'user') else 'Ayma'}: {m['content']}"
        for m in messages
    )
    llm = _llm()
    await asyncio.gather(
        *[_update_page(llm, user_id, page, prompt, exchange) for page, prompt in _PAGES]
    )
    logger.info(f"[wiki] updated 3 pages for {user_id}")
