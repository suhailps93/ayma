"""
/internal/memory-write handler

Called by Cloud Tasks after every conversation turn.
Runs two things in parallel:
1. Embed the last message and store it in pgvector (messages table)
2. Extract facts from the last exchange and upsert into Mem0
"""
import asyncio
import os
from google import genai as google_genai
from mem0 import MemoryClient
from supabase import create_client


def _clients():
    gc = google_genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=os.environ["GOOGLE_CLOUD_LOCATION"],
    )
    mem0 = MemoryClient(api_key=os.environ["MEM0_API_KEY"])
    supabase = create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )
    return gc, mem0, supabase


async def _embed_and_store(gc, supabase, user_id: str, messages: list[dict]) -> None:
    """Embed each message and store in pgvector."""
    for msg in messages:
        emb = gc.models.embed_content(
            model="gemini-embedding-2-preview",
            contents=msg["content"],
        )
        vec = emb.embeddings[0].values
        vec_str = "[" + ",".join(str(v) for v in vec) + "]"

        supabase.table("messages").insert({
            "user_id": user_id,
            "role": "user" if msg["role"] == "human" else "assistant",
            "content": msg["content"],
            "embedding": vec_str,
        }).execute()


async def _update_mem0(mem0, user_id: str, messages: list[dict]) -> None:
    """Extract and store facts from the last exchange into Mem0."""
    # Mem0 expects [{"role": "user"|"assistant", "content": "..."}]
    normalized = [
        {"role": "user" if m["role"] == "human" else "assistant", "content": m["content"]}
        for m in messages
    ]
    mem0.add(normalized, user_id=user_id)


async def handle_memory_write(user_id: str, messages: list[dict]) -> None:
    gc, mem0, supabase = _clients()
    await asyncio.gather(
        _embed_and_store(gc, supabase, user_id, messages),
        _update_mem0(mem0, user_id, messages),
    )
