"""
memorize node — runs after the response is sent.

Enqueues two Cloud Tasks (fire-and-forget):
1. memory_write  — embed last message into pgvector + extract facts into Mem0
2. profile_update — rewrite all 3 profile tiers using Gemini Flash

Nothing here blocks the user. Both tasks run async via Cloud Tasks.
"""
import json
import os
from google.cloud import tasks_v2

from app.graph.state import AgentState

BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:8000")
CLOUD_TASKS_QUEUE = os.environ.get("CLOUD_TASKS_QUEUE", "")


def _enqueue(client: tasks_v2.CloudTasksClient, endpoint: str, body: dict) -> None:
    """Fire-and-forget: create a Cloud Task that hits an internal endpoint."""
    if not CLOUD_TASKS_QUEUE:
        # Local dev — skip Cloud Tasks, internal endpoints called directly
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


async def memorize(state: AgentState) -> AgentState:
    """Enqueue memory write and profile update tasks."""
    user_id = state["user_id"]

    # Last exchange = last human message + last AI response
    last_exchange = [
        m for m in state["messages"][-4:]  # at most last 2 turns
        if m.type in ("human", "ai")
    ]
    serialized = [{"role": m.type, "content": m.content} for m in last_exchange]

    try:
        client = tasks_v2.CloudTasksClient()
        _enqueue(client, "/internal/memory-write", {
            "user_id": user_id,
            "messages": serialized,
        })
        _enqueue(client, "/internal/update-profile", {
            "user_id": user_id,
        })
    except Exception:
        pass  # never fail a user turn because of a background task issue

    return state
