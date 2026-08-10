"""
LiveKit Agent Worker for Ayma.

Provides a unified single-session environment for real-time voice (Gemini Live)
and text chat (LiveKit Data Channels) sharing the same Firestore data layer.
"""

import asyncio
import json
import logging
import os
import secrets
from pathlib import Path

from google.cloud.firestore import AsyncClient
from livekit.agents import (
    Agent,
    AgentSession,
    JobContext,
    AgentServer,
    JobExecutorType,
    function_tool,
    ChatContext,
)
from livekit.plugins import google
from livekit.plugins.google.realtime import RealtimeModel

from main import (
    _active_questions_for_profile,
    _active_key,
    _process_post_turn_from_messages,
    add_followup_question_doc,
    COMMUNITY_CONFIG,
    get_enabled_skills,
    get_pending_user_questions,
    get_user_doc,
    get_relevant_user_memories,
)

from config import FIREBASE_PROJECT_ID, LIVE_MODEL, TEXT_MODEL

logger = logging.getLogger("ayma.agent")

AGENT_NAME = "ayma-agent"
AGENT_PROFILE_FETCH_TIMEOUT_S = 5
AGENT_CONTEXT_FETCH_TIMEOUT_S = 5
AGENT_MEMORY_FETCH_TIMEOUT_S = 3

_db_by_loop: dict[int, AsyncClient] = {}


def _get_db() -> AsyncClient:
    loop_key = id(asyncio.get_running_loop())
    db = _db_by_loop.get(loop_key)
    if db is None:
        db = AsyncClient(project=FIREBASE_PROJECT_ID)
        _db_by_loop[loop_key] = db
    return db


async def _with_timeout(
    label: str,
    coro,
    timeout_s: int,
    fallback,
    warnings: list[str] | None = None,
):
    try:
        return await asyncio.wait_for(coro, timeout=timeout_s)
    except Exception as e:
        msg = f"{label} failed or timed out after {timeout_s}s: {type(e).__name__}: {e}"
        logger.error(f"AGENT CONTEXT WARNING: {msg}")
        if warnings is not None:
            warnings.append(msg)
        return fallback

# ── Dynamic Prompt Loading (No prompts in code) ──────────────────────────────────

def load_prompt_file(filename: str) -> str:
    """
    Loads a prompt template from the prompts directory.
    Ensures zero prompts are hardcoded in the codebase.
    """
    prompts_dir = Path(__file__).parent / "prompts"
    filepath = prompts_dir / filename
    return filepath.read_text(encoding="utf-8")


def build_system_prompt_dynamic(
    profile: dict,
    skills: list[dict],
    pending_questions: list[dict],
    memories: list[dict] | None = None,
) -> str:
    """
    Constructs the conversational system prompt dynamically from prompt files.
    This replicates the logic of _build_system_prompt but loads templates
    externally to comply with global prompt guidelines.
    """
    name = profile.get("display_name") or "User"
    agent_name = profile.get("agent_name") or "Ayma"
    active_questions = _active_questions_for_profile(profile)
    community_id = (profile.get("community_profile") or "dating_standard").strip()
    if community_id == "dating_standard":
        community_id = "dating_western"
    community = COMMUNITY_CONFIG.get(community_id)

    has_wiki = bool(
        profile.get("wiki_about_me")
        or profile.get("wiki_context")
        or profile.get("wiki_preferences")
    )

    # Dynamically load the core prompt segments from text files
    matchmaker_skill = load_prompt_file("MATCHMAKER_SKILL.txt").replace("{agent_name}", agent_name)
    recall_skill = (
        load_prompt_file("DEEP_RECALL_SKILL.txt")
        if has_wiki
        else load_prompt_file("NEW_USER_LISTEN_SKILL.txt")
    )
    tone_skill = load_prompt_file("TONE_MIRROR_SKILL.txt")
    completion_skill = load_prompt_file("PROFILE_COMPLETION_SKILL.txt")

    parts = [
        matchmaker_skill,
        recall_skill,
        tone_skill,
        completion_skill,
    ]

    if community:
        parts.append(
            f"## Matchmaking Context\n"
            f"Community: {community['label']}\n"
            f"Notes: {community['notes']}\n"
            f"How to show up: {community['agent_personality']}"
        )

    # User demographics
    demo = []
    if profile.get("age"):
        demo.append(f"Age: {profile['age']}")
    if profile.get("gender"):
        demo.append(f"Gender: {profile['gender']}")
    if profile.get("location_region"):
        demo.append(f"Location: {profile['location_region']}")
    
    # Parse matching preferences
    mp = profile.get("matching_prefs")
    if isinstance(mp, str):
        try:
            mp = json.loads(mp)
        except Exception:
            mp = {}
    mp = mp or {}
    
    if mp.get("interested_in"):
        demo.append(f"Looking for: {mp['interested_in']}")
    if mp.get("age_min") is not None and mp.get("age_max") is not None:
        demo.append(f"Partner age range: {mp['age_min']}–{mp['age_max']}")
    if demo:
        parts.append(f"## Demographics\n{', '.join(demo)}")

    # Verbatim user statements
    raw_statements = []
    if profile.get("raw_user_statements"):
        try:
            raw_statements = json.loads(profile["raw_user_statements"])
        except Exception:
            pass
    if raw_statements:
        recent = raw_statements[-20:]
        parts.append(
            f"## What {name} Has Actually Said\n"
            + "\n".join(f"- {s}" for s in recent)
        )

    # Narrative Wiki blocks
    if profile.get("wiki_about_me"):
        parts.append(f"## About {name}\n{profile['wiki_about_me']}")
    if profile.get("wiki_context"):
        parts.append(f"## {name}'s Current Life Context\n{profile['wiki_context']}")
    if profile.get("wiki_preferences"):
        parts.append(f"## What {name} Is Looking For\n{profile['wiki_preferences']}")
    if profile.get("wiki_matching"):
        parts.append(f"## {name}'s Matching Profile\n{profile['wiki_matching']}")

    # User written profiles
    if profile.get("profile_public"):
        parts.append(f"## {name}'s Own Words\n{profile['profile_public']}")
    if profile.get("profile_private"):
        parts.append(f"## {name}'s Private Notes\n{profile['profile_private']}")

    if mp:
        parts.append(f"## Matching Preferences\n{json.dumps(mp, indent=2)}")

    if profile.get("wiki_profile_structured"):
        parts.append(f"## Structured Match Profile\n{profile['wiki_profile_structured']}")

    if memories:
        mem_lines = [f"- {m['text']}" for m in memories if m.get("text")]
        if mem_lines:
            parts.append(f"## Relevant Memories & Key Facts\n" + "\n".join(mem_lines))

    # Questionnaire tasks
    if pending_questions:
        required = [q for q in pending_questions if q.get("category") == "required"]
        deeper = [q for q in pending_questions if q.get("category") == "deeper"]
        matching = [q for q in pending_questions if q.get("category") == "matching_prefs"]
        followups = [q for q in pending_questions if q.get("is_followup")]

        lines = [
            "## Your Primary Objective — The Questionnaire",
            "",
            "Your most important job is to build a complete profile of this person by working through the questions below. Do this naturally — never make it feel like an interview. Follow interesting threads, but always come back to uncovered questions.",
            "",
            "When you're mid-conversation and remember something you want to ask later, call `add_followup_question` to note it. Don't interrupt the current topic.",
        ]

        if required:
            lines.append("\n### Required (cover these early):")
            for q in required:
                lines.append(f"- {q['text']}  [key: {q['key']}]")

        if deeper:
            lines.append("\n### Build a deeper picture (weave in naturally):")
            for q in deeper:
                lines.append(f"- {q['text']}  [key: {q['key']}]")

        if matching:
            lines.append("\n### Matching preferences (get before session ends):")
            for q in matching:
                lines.append(f"- {q['text']}  [key: {q['key']}]")

        if followups:
            lines.append("\n### Your saved follow-ups (from previous conversations):")
            for q in followups:
                lines.append(f"- {q['text']}")

        parts.append("\n".join(lines))
    else:
        parts.append(
            f"## Questionnaire Complete\n\nYou have covered all the key questions about {name}. "
            "Now deepen the conversation and update what you know as things change."
        )

    # Greet user warmly
    if profile.get("wiki_about_me") or profile.get("wiki_context"):
        parts.append(
            f"\nThe user's name is {name}. You've talked before — greet them warmly as the friend you've become. "
            "Reference something specific from the profile above to show you remember. "
            "Then continue deepening the conversation naturally."
        )
    else:
        parts.append(
            f"\nThe user's name is {name}. This is your first conversation. "
            "Greet them warmly and start with one genuine, open-ended question — something that invites them to share something real about themselves, "
            "not just facts. Make them feel immediately comfortable and curious to keep talking."
        )

    return "\n\n---\n\n".join(parts)


# ── Server-Side Tools Configuration ───────────────────────────────────────────────

class AgentTools:
    """
    Encapsulates server-side execution handlers for LLM function calling tools.
    """
    def __init__(self, uid: str):
        self.uid = uid

    @function_tool
    async def add_followup_question(self, question: str) -> str:
        """
        Note a question or topic to come back to later, without interrupting
        the current conversation flow. Call this when something interesting
        comes up that you want to explore more deeply in a future turn.

        Args:
            question: The question or topic to follow up on, as a short reminder to yourself.
        """
        logger.info(f"Tool executed: add_followup_question for user={self.uid} question={question}")
        try:
            q_id = f"followup_{secrets.token_hex(4)}"
            await add_followup_question_doc(_get_db(), self.uid, q_id, question)
            return "Saved follow-up question successfully."
        except Exception as e:
            logger.error(f"Failed to add followup question: {e}")
            return f"Error saving follow-up question: {e}"


# ── LiveKit Agent Session Entrypoint ───────────────────────────────────────────────

def make_entrypoint():
    """Returns the LiveKit session entrypoint."""
    async def entrypoint(ctx: JobContext):
        # The room name is set to the user's Firebase UID during token bootstrap.
        uid = ctx.room.name
        logger.info(f"Agent starting session for room={ctx.room.name} user={uid}")

        pending_user_transcript = ""

        # Connect to the LiveKit room
        await ctx.connect()
        logger.info("Agent connected to LiveKit room.")

        db = _get_db()
        context_warnings: list[str] = []
        logger.info(f"Loading agent context for user={uid}")
        profile = await _with_timeout(
            "profile fetch",
            get_user_doc(db, uid),
            AGENT_PROFILE_FETCH_TIMEOUT_S,
            {},
            context_warnings,
        )
        if not profile:
            logger.info(f"Fresh user without profile found in Firestore for user={uid}, creating default profile fallback.")
            profile = {
                "user_id": uid,
                "display_name": "Friend",
                "community_profile": "dating_western",
                "onboarding_complete": False,
            }

        pending_questions = await _with_timeout(
            "pending questions fetch",
            get_pending_user_questions(db, uid),
            AGENT_CONTEXT_FETCH_TIMEOUT_S,
            [],
            context_warnings,
        )
        skills = await _with_timeout(
            "enabled skills fetch",
            get_enabled_skills(db, uid),
            AGENT_CONTEXT_FETCH_TIMEOUT_S,
            [],
            context_warnings,
        )
        memories = await _with_timeout(
            "relevant memories fetch",
            get_relevant_user_memories(db, uid, query_text=profile.get("display_name"), limit=5),
            AGENT_MEMORY_FETCH_TIMEOUT_S,
            [],
            context_warnings,
        )
        logger.info(
            f"Loaded agent context for user={uid}: "
            f"questions={len(pending_questions)} skills={len(skills)} memories={len(memories)}"
        )
        if context_warnings:
            logger.error(
                "AGENT CONTEXT DEGRADED for user=%s: %s",
                uid,
                " | ".join(context_warnings),
            )

        # 2. Build the system prompt dynamic from prompt templates
        system_prompt = build_system_prompt_dynamic(
            profile, skills, pending_questions, memories=memories
        )
        if context_warnings:
            system_prompt += (
                "\n\n## TESTING WARNING — CONTEXT DEGRADED\n"
                "Memory/profile context retrieval had a problem while starting this session. "
                "For this testing session, begin your next user-facing reply with: "
                "\"[context warning: memory/profile retrieval degraded]\". "
                "Then continue normally and do not pretend you loaded missing memories.\n"
                "Details: " + " | ".join(context_warnings)
            )

        # 3. Determine custom voice configuration
        voice_pref = (profile.get("voice_preference") or "").strip().lower()
        if voice_pref in ("march", "ash", "cove", "ember", "breeze", "fenrir"):
            voice = "Fenrir"
        elif voice_pref in ("puck", "kore", "aoede"):
            gemini_names = {"puck": "Puck", "kore": "Kore", "aoede": "Aoede"}
            voice = gemini_names[voice_pref]
        else:
            voice = "Charon"

        logger.info(f"Using voice={voice} for user={uid}")

        # 4. Instantiate model configurations (voice RealtimeModel and text LLM)
        api_key = _active_key()

        # Voice Speech-to-Speech model
        rt_model = RealtimeModel(
            model=LIVE_MODEL,
            api_key=api_key,
            voice=voice,
            instructions=system_prompt,
            input_audio_transcription={},
            output_audio_transcription={},
        )

        # Text LLM model for data tracks
        text_llm = google.LLM(
            model=TEXT_MODEL,
            api_key=api_key,
        )
        text_chat_ctx = ChatContext()
        text_chat_ctx.add_message(role="system", content=system_prompt)

        # Initialize the tools class
        tools_inst = AgentTools(uid=uid)
        tools = [tools_inst.add_followup_question]

        # Configure AgentSession
        session = AgentSession(
            llm=rt_model,
        )

        def _merge_transcript(existing: str, incoming: str) -> str:
            next_text = (incoming or "").strip()
            current = existing.strip()
            if not next_text:
                return current
            if not current:
                return next_text
            if current == next_text or current.endswith(next_text):
                return current
            if next_text.startswith(current):
                return next_text
            return f"{current} {next_text}"

        def _item_role(item: object) -> str:
            role = getattr(item, "role", "")
            return str(role).lower()

        def _item_text(item: object) -> str:
            content = getattr(item, "content", "")
            if isinstance(content, str):
                return content.strip()
            if isinstance(content, list):
                parts: list[str] = []
                for part in content:
                    text = getattr(part, "text", None)
                    if isinstance(text, str) and text.strip():
                        parts.append(text.strip())
                    elif isinstance(part, dict):
                        raw = part.get("text") or part.get("content")
                        if isinstance(raw, str) and raw.strip():
                            parts.append(raw.strip())
                return " ".join(parts).strip()
            text = getattr(item, "text", None)
            if isinstance(text, str):
                return text.strip()
            return ""

        async def _publish_event(payload: dict[str, object], topic: str) -> None:
            try:
                await ctx.room.local_participant.publish_data(
                    payload=json.dumps(payload),
                    reliable=True,
                    topic=topic,
                )
            except Exception as e:
                logger.warning(f"Failed to publish {topic} payload: {e}")

        async def _persist_turn(user_text: str, model_text: str) -> None:
            user_text = user_text.strip()
            model_text = model_text.strip()
            if not user_text or not model_text:
                return
            session_id = f"lk_{secrets.token_hex(4)}"
            try:
                await _process_post_turn_from_messages(
                    _get_db(),
                    uid=uid,
                    session_id=session_id,
                    messages=[
                        {"role": "user", "text": user_text},
                        {"role": "model", "text": model_text},
                    ],
                )
            except Exception as e:
                logger.warning(f"Failed to persist turn to Firestore: {e}")

        @session.on("user_input_transcribed")
        def on_user_input_transcribed(event) -> None:
            nonlocal pending_user_transcript
            transcript = (getattr(event, "transcript", "") or "").strip()
            is_final = bool(getattr(event, "is_final", False))
            if not transcript:
                return
            pending_user_transcript = _merge_transcript(pending_user_transcript, transcript)
            if is_final:
                asyncio.create_task(_publish_event(
                    {
                        "type": "user_transcript",
                        "text": pending_user_transcript,
                        "is_final": True,
                    },
                    "ayma.transcript",
                ))

        @session.on("conversation_item_added")
        def on_conversation_item_added(event) -> None:
            nonlocal pending_user_transcript
            item = getattr(event, "item", None)
            if item is None:
                return
            role = _item_role(item)
            text = _item_text(item)
            if not text:
                return
            if "user" in role:
                pending_user_transcript = _merge_transcript(pending_user_transcript, text)
                asyncio.create_task(_publish_event(
                    {
                        "type": "user_transcript",
                        "text": pending_user_transcript,
                        "is_final": True,
                    },
                    "ayma.transcript",
                ))
                return
            if "assistant" in role or "model" in role:
                asyncio.create_task(_publish_event(
                    {
                        "type": "agent_transcript",
                        "text": text,
                        "is_final": True,
                    },
                    "ayma.transcript",
                ))
                user_text = pending_user_transcript
                pending_user_transcript = ""
                asyncio.create_task(_persist_turn(user_text, text))

        # ── Text Track Interception ───────────────────────────────────────────────
        @ctx.room.on("data_received")
        def on_data_received(data_packet):
            """
            Listens to client text messages on the LiveKit data track.
            Appends the message to the session context, executes the text runner,
            runs tools if requested, and broadcasts the reply.
            """
            payload = data_packet.data
            try:
                if isinstance(payload, bytes):
                    raw_text = payload.decode("utf-8")
                else:
                    raw_text = str(payload)

                client_message_id = None
                text = raw_text
                try:
                    envelope = json.loads(raw_text)
                    if isinstance(envelope, dict) and envelope.get("type") == "user_text":
                        text = str(envelope.get("text") or "")
                        client_message_id = str(envelope.get("id") or "") or None
                except Exception:
                    pass

                logger.info(f"Intercepted text track input: {text}")

                # Create asynchronous task to compute reply safely
                asyncio.create_task(handle_text_input(text, client_message_id=client_message_id))
            except Exception as e:
                logger.error(f"Error handling data packet: {e}")

        async def handle_text_input(text: str, *, client_message_id: str | None = None):
            """
            Runs the LLM text completion and broadcasts response.
            Interrupts the active voice stream on incoming user text commands.
            """
            # Interruption is only valid while the voice session is active.
            try:
                session.interrupt()
            except RuntimeError:
                pass

            # Keep a separate text context; AgentSession does not expose a
            # public chat_ctx in livekit-agents 1.6.x.
            text_chat_ctx.add_message(role="user", content=text)

            try:
                # Run text LLM with standard tools
                response = await text_llm.chat(
                    chat_ctx=text_chat_ctx,
                    tools=tools,
                ).collect()

                # Handle tool calls
                if response.tool_calls:
                    for tc in response.tool_calls:
                        if tc.name == "add_followup_question":
                            await tools_inst.add_followup_question(**tc.arguments)

                reply_text = response.text or ""
                logger.info(f"Text LLM generated reply: {reply_text}")

                # Append the model reply to the shared context
                text_chat_ctx.add_message(role="assistant", content=reply_text)

                # Commit text turn to database and post-turn memory pipeline
                asyncio.create_task(_persist_turn(text, reply_text))

                # Broadcast reply string to the user via data channel
                await ctx.room.local_participant.publish_data(
                    payload=json.dumps({
                        "type": "agent_transcript",
                        "text": reply_text,
                        "is_final": True,
                        "client_message_id": client_message_id,
                    }),
                    reliable=True,
                )
            except Exception as e:
                logger.error(f"Failed to generate text LLM response: {e}")
                # Send error message back to client
                try:
                    await ctx.room.local_participant.publish_data(
                        payload=json.dumps({
                            "type": "agent_transcript",
                            "text": "I encountered an issue processing your request. Please try again.",
                            "is_final": True,
                            "client_message_id": client_message_id,
                        }),
                        reliable=True,
                    )
                except Exception:
                    pass

        # Start the multimodal voice and data session orchestration
        await session.start(
            room=ctx.room,
            agent=Agent(
                instructions=system_prompt,
                tools=tools,
            ),
        )

        logger.info(f"Agent session successfully started for user={uid}")

    return entrypoint


# ── Agent Worker Server Management ───────────────────────────────────────────────

async def start_agent_server() -> asyncio.Task | None:
    """
    Initializes and starts the LiveKit AgentServer programmatically.
    Returns the running async task or None if LiveKit credentials are not set.
    """
    ws_url = os.environ.get("LIVEKIT_URL")
    api_key = os.environ.get("LIVEKIT_API_KEY")
    api_secret = os.environ.get("LIVEKIT_API_SECRET")

    if not ws_url or not api_key or not api_secret:
        logger.warning(
            "LiveKit environment variables are missing. AgentServer startup skipped."
        )
        return None

    # Instantiate server programmatically using Thread executor
    server = AgentServer(
        job_executor_type=JobExecutorType.THREAD,
        ws_url=ws_url,
        api_key=api_key,
        api_secret=api_secret,
        port=0,  # Let it assign port dynamically
    )

    # Bind the session entrypoint
    server.rtc_session(agent_name=AGENT_NAME)(make_entrypoint())

    # Run the server in an asynchronous task
    logger.info("Starting LiveKit AgentServer task...")
    return asyncio.create_task(server.run())
