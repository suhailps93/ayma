"""
Ayma LangGraph agent graph.

Topology:  retrieve → personality → respond → memorize

The graph uses a PostgreSQL checkpointer (langgraph-checkpoint-postgres)
so conversation state persists across sessions and server restarts.
Each user's conversation history lives in its own thread_id = user_id.
"""
import os
from langgraph.graph import StateGraph, END
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

from app.graph.state import AgentState
from app.graph.nodes.retrieve import retrieve
from app.graph.nodes.personality import personality
from app.graph.nodes.respond import respond
from app.graph.nodes.memorize import memorize


def build_graph(checkpointer=None) -> StateGraph:
    """Build and compile the agent graph."""
    builder = StateGraph(AgentState)

    builder.add_node("retrieve", retrieve)
    builder.add_node("personality", personality)
    builder.add_node("respond", respond)
    builder.add_node("memorize", memorize)

    builder.set_entry_point("retrieve")
    builder.add_edge("retrieve", "personality")
    builder.add_edge("personality", "respond")
    builder.add_edge("respond", "memorize")
    builder.add_edge("memorize", END)

    return builder.compile(checkpointer=checkpointer)


async def get_graph():
    """Return a compiled graph with a live PostgreSQL checkpointer."""
    db_url = os.environ["SUPABASE_DB_URL"].replace(
        "postgresql://", "postgresql+psycopg://"
    )
    async with AsyncPostgresSaver.from_conn_string(db_url) as checkpointer:
        await checkpointer.setup()  # creates langgraph checkpoint tables if needed
        return build_graph(checkpointer)
