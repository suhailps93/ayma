"""
Quick interactive test for the Ayma agent graph.
Run with: .venv/bin/python chat.py

Creates a temporary test user, lets you chat, cleans up on exit (Ctrl+C).
Pass --keep to leave the user and their data in the DB after the session.
"""
import asyncio
import httpx
import os
import sys
import time
import argparse

from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

from langchain_core.messages import HumanMessage, AIMessage
from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_KEY  = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
HEADERS      = {
    "apikey": SERVICE_KEY,
    "Authorization": f"Bearer {SERVICE_KEY}",
    "Content-Type": "application/json",
}
TEST_EMAIL = "chat_test@ayma.local"


def setup_user() -> str:
    """Create (or reuse) a test user and return their ID."""
    # Check if test user already exists
    users = httpx.get(f"{SUPABASE_URL}/auth/v1/admin/users", headers=HEADERS).json()
    existing = next((u for u in users.get("users", []) if u.get("email") == TEST_EMAIL), None)
    if existing:
        return existing["id"]

    r = httpx.post(f"{SUPABASE_URL}/auth/v1/admin/users", headers=HEADERS,
        json={"email": TEST_EMAIL, "password": "TestPass123!", "email_confirm": True})
    time.sleep(1)
    return r.json()["id"]


def cleanup_user(user_id: str) -> None:
    httpx.delete(f"{SUPABASE_URL}/auth/v1/admin/users/{user_id}", headers=HEADERS)


async def chat_loop(user_id: str) -> None:
    from app.graph import build_graph
    graph = build_graph()

    state = {
        "user_id": user_id,
        "mode": "text",
        "messages": [],
        "mem0_facts": "",
        "rag_context": "",
        "system_prompt": "",
        "response": "",
        "exclusion_detected": False,
        "exclusion_topic": None,
    }

    print("\n" + "="*55)
    print("  Ayma — interactive test chat")
    print("  Type your message and press Enter")
    print("  Ctrl+C to exit")
    print("="*55 + "\n")

    while True:
        try:
            user_input = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting...")
            break

        if not user_input:
            continue

        state = {
            **state,
            "messages": state["messages"] + [HumanMessage(content=user_input)],
            "exclusion_detected": False,
            "exclusion_topic": None,
        }

        try:
            state = await graph.ainvoke(state)
        except Exception as e:
            print(f"[error] {e}")
            continue

        print(f"\nAyma: {state['response']}")

        if state.get("exclusion_detected"):
            print(f"  [note: exclusion stored — '{state['exclusion_topic']}' hidden from public profile]")

        print()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="Keep test user after session")
    args = parser.parse_args()

    print("Setting up test user...")
    user_id = setup_user()
    print(f"User ID: {user_id}")

    try:
        await chat_loop(user_id)
    finally:
        if not args.keep:
            print("Cleaning up test user...")
            cleanup_user(user_id)
        else:
            print(f"Kept user {user_id} (email: {TEST_EMAIL})")


if __name__ == "__main__":
    asyncio.run(main())
