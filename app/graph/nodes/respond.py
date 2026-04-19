"""
respond node — calls Gemini Flash and streams the response.

Also handles exclusion detection: if the user says something like
"don't put my job in my profile", this node detects it synchronously
before generating the main response, so the user gets an immediate
acknowledgment in the same turn.
"""
import json
import os
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.messages import SystemMessage, AIMessage
from supabase import create_client

from app.model_config import FAST_MODEL
from app.graph.state import AgentState

EXCLUSION_DETECTION_PROMPT = """Does this message ask to remove or hide something from the user's profile?
If yes, return JSON: {"is_exclusion": true, "topic": "<brief description>"}
If no, return JSON: {"is_exclusion": false}
Respond only with JSON. No explanation."""

DEFERRED_QUESTION_PROMPT = """You are reviewing a conversation turn between an AI matchmaker and a user.

The AI's response is shown below. Did the AI hold back a question it wanted to ask because
the moment wasn't right or it would interrupt the conversational flow?

If yes, return JSON: {"has_deferred": true, "question": "<the question it should ask later, in plain english>"}
If no, return JSON: {"has_deferred": false}
Respond only with JSON. No explanation.

AI response to review:
{response}"""


def _get_supabase():
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )


def _get_llm(streaming: bool = False) -> ChatGoogleGenerativeAI:
    return ChatGoogleGenerativeAI(
        model=FAST_MODEL,
        temperature=0.7,
    )


async def _detect_exclusion(message: str) -> tuple[bool, str | None]:
    """Check if the message is asking to hide something from the profile."""
    try:
        llm = _get_llm()
        result = await llm.ainvoke([
            SystemMessage(content=EXCLUSION_DETECTION_PROMPT),
            {"role": "user", "content": message},
        ])
        # Strip markdown code fences if the model wraps the JSON
        raw = result.content.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        parsed = json.loads(raw.strip())
        if parsed.get("is_exclusion"):
            return True, parsed.get("topic")
    except Exception:
        pass
    return False, None


async def _store_exclusion(user_id: str, topic: str) -> None:
    supabase = _get_supabase()
    supabase.table("profile_exclusions").insert({
        "user_id": user_id,
        "topic": topic,
        "tier": "public",
    }).execute()


async def respond(state: AgentState) -> AgentState:
    """Generate response. Detect and store profile exclusions inline."""
    user_id = state["user_id"]
    last_user_msg = next(
        (m.content for m in reversed(state["messages"]) if m.type == "human"),
        "",
    )

    # Check for exclusion intent before generating the main response
    exclusion_detected, exclusion_topic = await _detect_exclusion(last_user_msg)
    if exclusion_detected and exclusion_topic:
        await _store_exclusion(user_id, exclusion_topic)

    # Build messages list with system prompt prepended
    llm_messages = [SystemMessage(content=state["system_prompt"])] + state["messages"]

    # Generate response
    llm = _get_llm(streaming=True)
    response_text = ""
    async for chunk in llm.astream(llm_messages):
        response_text += chunk.content

    # Detect deferred questions — runs after response, doesn't block user
    new_pending = list(state.get("questions_pending", []))
    try:
        llm_fast = _get_llm()
        check = await llm_fast.ainvoke([
            SystemMessage(content=DEFERRED_QUESTION_PROMPT.format(response=response_text)),
            {"role": "user", "content": "Did the AI defer a question?"},
        ])
        raw = check.content.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        parsed = json.loads(raw.strip())
        if parsed.get("has_deferred") and parsed.get("question"):
            q = parsed["question"]
            
            # Fetch current from DB to ensure we have the latest
            supabase = _get_supabase()
            current_db = supabase.table("user_profiles").select("questions_pending").eq("id", user_id).single().execute()
            db_pending = current_db.data.get("questions_pending") if current_db.data else []
            if not isinstance(db_pending, list): db_pending = []
            
            if q not in db_pending:
                db_pending.append(q)
                supabase.table("user_profiles").update({"questions_pending": db_pending}).eq("id", user_id).execute()
            
            new_pending = db_pending
    except Exception as e:
        print(f"Error updating pending questions: {e}")
        pass

    return {
        **state,
        "messages": [AIMessage(content=response_text)],
        "response": response_text,
        "exclusion_detected": exclusion_detected,
        "exclusion_topic": exclusion_topic,
        "questions_pending": new_pending,
    }
