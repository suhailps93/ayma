"""
retrieve node — runs at the start of every turn.

Fetches two things in parallel:
1. Mem0 facts      — who this person is ("User is a vegetarian", "has a dog named Mango")
2. pgvector RAG    — past messages semantically similar to the current message

Both are injected into the system prompt by the personality node.
Token caps are enforced here to keep the context budget under control.
"""
import asyncio
import os
from google import genai as google_genai
from mem0 import MemoryClient
from supabase import create_client

from app.graph.state import AgentState

# Token caps — see docs/memory.md for the full budget breakdown
MEM0_TOKEN_CAP = 600
RAG_TOKEN_CAP = 400
RAG_RESULTS = 8   # fetch 8 messages, trim to token cap after


def _get_supabase():
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )


def _get_mem0():
    return MemoryClient(api_key=os.environ["MEM0_API_KEY"])


def _get_genai():
    return google_genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=os.environ["GOOGLE_CLOUD_LOCATION"],
    )


def _trim_to_tokens(text: str, max_tokens: int) -> str:
    """Rough token trimming — 1 token ≈ 4 characters."""
    max_chars = max_tokens * 4
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "\n[trimmed]"


async def _fetch_mem0_facts(user_id: str) -> str:
    """Fetch structured facts about the user from Mem0."""
    try:
        mem0 = _get_mem0()
        results = mem0.get_all(user_id=user_id)
        if not results:
            return ""
        # results is a dict with a "results" key in Mem0 v1+
        items = results if isinstance(results, list) else results.get("results", [])
        facts = "\n".join(f"- {r['memory']}" for r in items)
        return _trim_to_tokens(facts, MEM0_TOKEN_CAP)
    except Exception:
        return ""  # graceful degradation — agent still works without memory


async def _fetch_rag_context(user_id: str, query: str) -> str:
    """Fetch past messages semantically similar to the current message."""
    try:
        gc = _get_genai()
        emb = gc.models.embed_content(
            model="gemini-embedding-2-preview",
            contents=query,
        )
        vec = emb.embeddings[0].values
        vec_str = "[" + ",".join(str(v) for v in vec) + "]"

        supabase = _get_supabase()
        result = supabase.rpc("match_messages", {
            "query_embedding": vec_str,
            "match_user_id": user_id,
            "match_count": RAG_RESULTS,
        }).execute()

        if not result.data:
            return ""

        lines = [f"{r['role']}: {r['content']}" for r in result.data]
        context = "\n".join(lines)
        return _trim_to_tokens(context, RAG_TOKEN_CAP)
    except Exception:
        return ""


async def retrieve(state: AgentState) -> AgentState:
    """Fetch Mem0 facts and RAG context in parallel."""
    user_id = state["user_id"]
    # Use the last user message as the RAG query
    last_user_msg = next(
        (m.content for m in reversed(state["messages"]) if m.type == "human"),
        "",
    )

    mem0_facts, rag_context = await asyncio.gather(
        _fetch_mem0_facts(user_id),
        _fetch_rag_context(user_id, last_user_msg),
    )

    return {
        **state,
        "mem0_facts": mem0_facts,
        "rag_context": rag_context,
    }
