"""
retrieve node — runs at the start of every turn.

Fetches three things in parallel:
1. Mem0 facts      — atomic facts about this person
2. Wiki context    — synthesized per-user knowledge base from GCS
3. Recent messages — last N messages from DB (no embedding needed)

Wiki replaces the old pgvector semantic search. The wiki is richer and already
synthesized — the LLM maintains it after each turn via wiki_update.py.
Recent messages give conversation continuity without re-embedding anything.
"""
import asyncio
import os

from mem0 import MemoryClient
from supabase import create_client

from app.graph.state import AgentState
from app.wiki import read_all_wiki_pages

MEM0_TOKEN_CAP = 600
RECENT_MESSAGES = 10


def _get_supabase():
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )


def _get_mem0():
    return MemoryClient(api_key=os.environ["MEM0_API_KEY"])


def _trim_to_tokens(text: str, max_tokens: int) -> str:
    max_chars = max_tokens * 4
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "\n[trimmed]"


async def _fetch_mem0_facts(user_id: str) -> str:
    try:
        mem0 = _get_mem0()
        results = mem0.get_all(user_id=user_id)
        if not results:
            return ""
        items = results if isinstance(results, list) else results.get("results", [])
        facts = "\n".join(f"- {r['memory']}" for r in items)
        return _trim_to_tokens(facts, MEM0_TOKEN_CAP)
    except Exception:
        return ""


async def _fetch_wiki_context(user_id: str) -> str:
    try:
        import asyncio as _asyncio
        return await _asyncio.to_thread(read_all_wiki_pages, user_id)
    except Exception:
        return ""


async def _fetch_recent_messages(user_id: str) -> str:
    try:
        supabase = _get_supabase()
        result = (
            supabase.table("messages")
            .select("role, content")
            .eq("user_id", user_id)
            .order("created_at", desc=True)
            .limit(RECENT_MESSAGES)
            .execute()
        )
        if not result.data:
            return ""
        rows = list(reversed(result.data))
        return "\n".join(f"{r['role']}: {r['content']}" for r in rows)
    except Exception:
        return ""


async def retrieve(state: AgentState) -> AgentState:
    user_id = state["user_id"]
    mem0_facts, wiki_context, rag_context = await asyncio.gather(
        _fetch_mem0_facts(user_id),
        _fetch_wiki_context(user_id),
        _fetch_recent_messages(user_id),
    )
    return {
        **state,
        "mem0_facts": mem0_facts,
        "wiki_context": wiki_context,
        "rag_context": rag_context,
    }
