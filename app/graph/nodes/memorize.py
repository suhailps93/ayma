"""
memorize node — runs after the response is sent.

Enqueues three Cloud Tasks (fire-and-forget):
1. memory_write  — embed last message into pgvector + extract facts into Mem0
2. profile_update — rewrite all 3 profile tiers using Gemini Flash
3. wiki_update   — update per-user wiki pages (about_me, preferences, context)

Nothing here blocks the user. All tasks run async via Cloud Tasks.
In local dev (CLOUD_TASKS_QUEUE unset), the same handlers run in-process.
"""
import asyncio
import json
import os

from google.cloud import tasks_v2

from app.graph.state import AgentState

BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:8000")
CLOUD_TASKS_QUEUE = os.environ.get("CLOUD_TASKS_QUEUE", "")


def _enqueue(client: tasks_v2.CloudTasksClient, endpoint: str, body: dict) -> None:
    if not CLOUD_TASKS_QUEUE:
        return
    task = {
        "http_request": {
            "http_method": tasks_v2.HttpMethod.POST,
            "url": f"{BACKEND_URL}{endpoint}",
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body).encode(),
        }
    }
    client.create_task(parent=CLOUD_TASKS_QUEUE, task=task)


async def _run_local_handlers(user_id: str, messages: list[dict]) -> None:
    from app.internal.memory_write import handle_memory_write
    from app.internal.profile_update import handle_profile_update
    from app.internal.wiki_update import handle_wiki_update

    try:
        await asyncio.gather(
            handle_memory_write(user_id, messages),
            handle_profile_update(user_id),
            handle_wiki_update(user_id, messages),
        )
    except Exception:
        pass


async def memorize(state: AgentState) -> AgentState:
    user_id = state["user_id"]
    last_exchange = [
        m for m in state["messages"][-4:]
        if m.type in ("human", "ai")
    ]
    serialized = [{"role": m.type, "content": m.content} for m in last_exchange]

    if not CLOUD_TASKS_QUEUE:
        asyncio.create_task(_run_local_handlers(user_id, serialized))
        return state

    try:
        client = tasks_v2.CloudTasksClient()
        _enqueue(client, "/internal/memory-write", {
            "user_id": user_id,
            "messages": serialized,
        })
        _enqueue(client, "/internal/update-profile", {
            "user_id": user_id,
        })
        _enqueue(client, "/internal/wiki-update", {
            "user_id": user_id,
            "messages": serialized,
        })
    except Exception:
        pass

    return state
