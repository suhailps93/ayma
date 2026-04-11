from typing import Annotated, Literal
from langgraph.graph.message import add_messages
from langchain_core.messages import BaseMessage
from typing_extensions import TypedDict


class AgentState(TypedDict):
    # --- Input (set before the graph runs) ---
    user_id: str
    mode: Literal["text", "voice"]

    # --- Conversation history ---
    # add_messages is a LangGraph reducer: appends new messages instead of overwriting
    messages: Annotated[list[BaseMessage], add_messages]

    # --- Populated by retrieve node ---
    mem0_facts: str       # atomic facts from Mem0 ("User is a vegetarian...")
    wiki_context: str     # synthesized per-user knowledge base (GCS wiki pages)
    rag_context: str      # recent conversation messages

    # --- Populated by personality node ---
    system_prompt: str    # final assembled prompt sent to Gemini

    # --- Populated by respond node ---
    response: str                  # last assistant response text
    exclusion_detected: bool       # did user ask to hide something from their profile?
    exclusion_topic: str | None    # what they want hidden, e.g. "job"

    # --- Question tracking (persisted across sessions via checkpointer) ---
    # Questions the agent wanted to ask but deferred (wrong moment, bad flow)
    # Injected into the system prompt each turn so the agent remembers to ask them
    questions_pending: list[str]
