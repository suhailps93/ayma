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

ABOUT_ME_PROMPT = """You maintain a wiki page capturing who a person is — personality, \
values, lifestyle, career, hobbies, background, how they communicate.

## Last conversation turn
{exchange}

## Current page (update it — preserve what's accurate, add new things, correct outdated info)
{current}

Write the updated page. First person, natural and specific. Max 300 words.
Output only the page content."""

PREFERENCES_PROMPT = """You maintain a wiki page capturing what a person wants in a \
romantic partner — attraction, values alignment, dealbreakers, relationship goals, \
what they've said they need.

## Last conversation turn
{exchange}

## Current page (update it — preserve what's accurate, add new things, correct outdated info)
{current}

Write the updated page. Specific and honest. Max 200 words.
Output only the page content."""

CONTEXT_PROMPT = """You maintain a wiki page capturing a person's current life context — \
emotional state, recent events, what they're going through, short-term goals, \
what's on their mind right now.

## Last conversation turn
{exchange}

## Current page (update it — current context changes, so refresh what's stale)
{current}

Write the updated page. Only current, relevant context. Max 200 words.
Output only the page content."""

_PAGES = [
    ("about_me.md", ABOUT_ME_PROMPT),
    ("preferences.md", PREFERENCES_PROMPT),
    ("context.md", CONTEXT_PROMPT),
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
