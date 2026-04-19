import asyncio
import base64
import json
import logging
from contextlib import suppress
from pathlib import Path
from typing import Any

from app.graph.nodes.memorize import run_post_turn_updates

from fastapi import WebSocket
from google.genai import types
from websockets.exceptions import ConnectionClosedError

from app.agent import _build_instruction, _load_user_gender, _voice_for_gender, get_current_time, submit_feedback
from app.genai_client import create_genai_client
from app.model_config import LIVE_MODEL

logger = logging.getLogger(__name__)


class _ToolContextLike:
    def __init__(self, user_id: str) -> None:
        self.user_id = user_id


class _InstructionContext:
    def __init__(self, user_id: str) -> None:
        self.user_id = user_id


def _guess_media_mime(path: str) -> str:
    ext = Path(path).suffix.lower()
    return {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".webp": "image/webp",
        ".mp4": "video/mp4",
        ".mov": "video/quicktime",
    }.get(ext, "application/octet-stream")


def _load_media_bytes(media_url: str) -> tuple[bytes, str]:
    if media_url.startswith("gs://"):
        from google.cloud import storage

        bucket_name = media_url.removeprefix("gs://").split("/", 1)[0]
        blob_path = media_url.removeprefix(f"gs://{bucket_name}/")
        client = storage.Client()
        data = client.bucket(bucket_name).blob(blob_path).download_as_bytes()
        return data, _guess_media_mime(blob_path)

    path = Path(media_url)
    return path.read_bytes(), _guess_media_mime(path.name)


def _build_function_tools() -> list[types.Tool]:
    return [
        types.Tool(google_search=types.GoogleSearch()),
        types.Tool(
            function_declarations=[
                types.FunctionDeclaration(
                    name="get_current_time",
                    description="Return the current date and time in a given IANA timezone.",
                    parameters_json_schema={
                        "type": "object",
                        "properties": {
                            "timezone": {
                                "type": "string",
                                "description": "IANA timezone string such as Asia/Dubai or America/New_York.",
                            }
                        },
                    },
                ),
                types.FunctionDeclaration(
                    name="submit_feedback",
                    description="Capture user feedback about the conversation, app bugs, UX issues, or feature requests.",
                    parameters_json_schema={
                        "type": "object",
                        "properties": {
                            "issue": {
                                "type": "string",
                                "description": "Clear description of the user's complaint, preference, or request.",
                            },
                            "feedback_type": {
                                "type": "string",
                                "enum": ["personal_preference", "bug", "feature_request", "ux"],
                            },
                        },
                        "required": ["issue", "feedback_type"],
                    },
                ),
            ]
        ),
    ]


def _blob_from_payload(blob_payload: dict[str, Any]) -> types.Blob:
    mime_type = (
        blob_payload.get("mimeType")
        or blob_payload.get("mime_type")
        or "application/octet-stream"
    )
    data = blob_payload.get("data")
    if not isinstance(data, str) or not data:
        raise ValueError("Missing blob data")
    return types.Blob(data=base64.b64decode(data), mime_type=mime_type)


async def _tool_response(function_call: Any, user_id: str) -> types.FunctionResponse:
    args = function_call.args or {}

    if function_call.name == "get_current_time":
        result = get_current_time(timezone=args.get("timezone", "UTC"))
    elif function_call.name == "submit_feedback":
        result = await submit_feedback(
            issue=args.get("issue", ""),
            feedback_type=args.get("feedback_type", "ux"),
            tool_context=_ToolContextLike(user_id),
        )
    else:
        result = {"error": f"Unknown tool: {function_call.name}"}

    return types.FunctionResponse(
        id=function_call.id,
        name=function_call.name,
        response={"result": result},
    )


async def build_live_connect_config(user_id: str) -> types.LiveConnectConfig:
    instruction = await _build_instruction(_InstructionContext(user_id))  # type: ignore[arg-type]
    voice_name = _voice_for_gender(_load_user_gender(user_id))
    return types.LiveConnectConfig(
        response_modalities=[types.Modality.AUDIO],
        system_instruction=instruction,
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(
                    voice_name=voice_name,
                )
            )
        ),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        tools=_build_function_tools(),
    )


async def build_live_setup_payload(user_id: str) -> dict[str, Any]:
    config = await build_live_connect_config(user_id)
    setup = types.LiveClientMessage(
        setup=types.LiveClientSetup(
            model=f"models/{LIVE_MODEL}",
            generation_config=types.GenerationConfig(
                response_modalities=config.response_modalities,
                speech_config=config.speech_config,
            ),
            system_instruction=types.Content(
                role="system",
                parts=[types.Part(text=config.system_instruction or "")],
            ),
            tools=config.tools,
            input_audio_transcription=config.input_audio_transcription,
            output_audio_transcription=config.output_audio_transcription,
        )
    )
    return setup.model_dump(mode="json", by_alias=True, exclude_none=True)


async def execute_live_function_calls(function_calls: list[dict[str, Any]], user_id: str) -> list[dict[str, Any]]:
    responses = []
    for function_call in function_calls:
        call = types.FunctionCall.model_validate(function_call)
        response = await _tool_response(call, user_id)
        responses.append(response.model_dump(mode="json", by_alias=True, exclude_none=True))
    return responses


class GeminiLiveBridge:
    def __init__(self, websocket: WebSocket, user_id: str) -> None:
        self.websocket = websocket
        self.user_id = user_id
        self._closed = False
        self._pending_user_text = ""
        self._pending_agent_text = ""
        self._last_flushed_signature = ""

    async def _build_config(self) -> types.LiveConnectConfig:
        return await build_live_connect_config(self.user_id)

    async def _safe_send_json(self, payload: dict[str, Any]) -> bool:
        if self._closed:
            return False
        try:
            await self.websocket.send_json(payload)
            return True
        except RuntimeError:
            self._closed = True
            return False

    def _json_safe(self, value: Any) -> Any:
        if isinstance(value, bytes):
            return base64.b64encode(value).decode("ascii")
        if isinstance(value, dict):
            return {key: self._json_safe(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self._json_safe(item) for item in value]
        return value

    def _content_parts_from_payload(self, payload: dict[str, Any]) -> list[types.Part]:
        content = payload.get("content") if "content" in payload else payload
        parts_payload = content.get("parts", []) if isinstance(content, dict) else []
        parts: list[types.Part] = []

        for part in parts_payload:
            if not isinstance(part, dict):
                continue
            text = part.get("text")
            if isinstance(text, str) and text.strip():
                parts.append(types.Part(text=text))
                continue

            inline = part.get("inlineData") or part.get("inline_data")
            if isinstance(inline, dict):
                parts.append(types.Part(inline_data=_blob_from_payload(inline)))

        attachments = payload.get("attachments", [])
        if isinstance(attachments, list):
            for attachment in attachments:
                if not isinstance(attachment, dict):
                    continue
                media_url = attachment.get("url")
                if not isinstance(media_url, str) or not media_url:
                    continue
                try:
                    data, mime_type = _load_media_bytes(media_url)
                    parts.append(types.Part.from_bytes(data=data, mime_type=mime_type))
                except Exception as exc:
                    logger.warning("[live] failed to load attachment %s: %s", media_url, exc)

        return parts

    def _text_from_payload(self, payload: dict[str, Any]) -> str:
        content = payload.get("content") if "content" in payload else payload
        if not isinstance(content, dict):
            return ""
        parts_payload = content.get("parts", [])
        texts = [
            part.get("text", "").strip()
            for part in parts_payload
            if isinstance(part, dict) and isinstance(part.get("text"), str) and part.get("text", "").strip()
        ]
        return "\n".join(texts).strip()

    def _merge_transcript_text(self, current: str, incoming: str) -> str:
        normalized = incoming.strip()
        if not normalized:
            return current
        if not current:
            return normalized
        if current == normalized or current.endswith(normalized):
            return current
        if normalized.startswith(current):
            return normalized
        return f"{current} {normalized}".strip()

    def _capture_user_text(self, text: str) -> None:
        self._pending_user_text = self._merge_transcript_text(self._pending_user_text, text)

    def _capture_agent_text(self, text: str) -> None:
        self._pending_agent_text = self._merge_transcript_text(self._pending_agent_text, text)

    def _capture_turn_from_payload(self, payload: dict[str, Any]) -> bool:
        sc = payload.get("serverContent") if isinstance(payload.get("serverContent"), dict) else {}

        out_tx = (
            sc.get("outputTranscription")
            or sc.get("output_transcription")
            or payload.get("outputTranscription")
            or payload.get("output_transcription")
            or {}
        )
        in_tx = (
            sc.get("inputTranscription")
            or sc.get("input_transcription")
            or payload.get("inputTranscription")
            or payload.get("input_transcription")
            or {}
        )
        model_turn = sc.get("modelTurn") or payload.get("modelTurn") or payload.get("content") or {}

        if isinstance(in_tx, dict):
            text = in_tx.get("text")
            if isinstance(text, str) and text.strip():
                self._capture_user_text(text)

        if isinstance(out_tx, dict):
            text = out_tx.get("text")
            if isinstance(text, str) and text.strip():
                self._capture_agent_text(text)

        if isinstance(model_turn, dict):
            for part in model_turn.get("parts", []):
                if not isinstance(part, dict):
                    continue
                text = part.get("text")
                is_thought = bool(part.get("thought", False))
                if isinstance(text, str) and text.strip() and not is_thought:
                    self._capture_agent_text(text)

        turn_complete = (
            sc.get("turnComplete")
            or sc.get("turn_complete")
            or payload.get("turnComplete")
            or payload.get("turn_complete")
            or False
        )
        return bool(turn_complete)

    async def _flush_turn_updates(self, *, reason: str) -> None:
        messages: list[dict[str, str]] = []
        if self._pending_user_text.strip():
            messages.append({"role": "human", "content": self._pending_user_text.strip()})
        if self._pending_agent_text.strip():
            messages.append({"role": "ai", "content": self._pending_agent_text.strip()})

        self._pending_user_text = ""
        self._pending_agent_text = ""

        if not messages:
            return

        signature = json.dumps(messages, ensure_ascii=True, sort_keys=True)
        if signature == self._last_flushed_signature:
            logger.info("[live] skipping duplicate post-turn update reason=%s", reason)
            return

        self._last_flushed_signature = signature
        logger.info("[live] flushing post-turn updates reason=%s messages=%s", reason, len(messages))
        await run_post_turn_updates(self.user_id, messages)

    async def _forward_client_to_live(self, session: Any) -> None:
        try:
            while True:
                message = await self.websocket.receive()
                msg_type = message.get("type")
                if msg_type == "websocket.disconnect":
                    logger.info("[live] client websocket disconnected")
                    self._closed = True
                    break

                if "text" not in message:
                    continue

                data = message["text"]
                if not isinstance(data, str):
                    continue

                payload = json.loads(data)
                if not isinstance(payload, dict):
                    continue

                if "setup" in payload:
                    logger.info("[live] client setup received")
                    continue

                live_payload = payload.get("live_request", payload)
                if not isinstance(live_payload, dict):
                    continue

                blob_payload = live_payload.get("blob") or live_payload.get("audio")
                if isinstance(blob_payload, dict):
                    logger.info("[live] forwarding audio chunk to Gemini")
                    await session.send_realtime_input(audio=_blob_from_payload(blob_payload))
                    continue

                if "text" in live_payload and isinstance(live_payload["text"], str):
                    logger.info("[live] forwarding direct text to Gemini")
                    self._capture_user_text(live_payload["text"])
                    await session.send_realtime_input(text=live_payload["text"])
                    continue

                if "content" in live_payload or "attachments" in live_payload:
                    text = self._text_from_payload(live_payload)
                    if text and not live_payload.get("attachments"):
                        logger.info("[live] forwarding content text to Gemini")
                        self._capture_user_text(text)
                        await session.send_realtime_input(text=text)
                        continue

                    parts = self._content_parts_from_payload(live_payload)
                    if parts:
                        logger.info("[live] forwarding %s multipart client parts to Gemini", len(parts))
                        await session.send_client_content(
                            turns=types.Content(role="user", parts=parts),
                            turn_complete=True,
                        )
                        continue

                logger.info("[live] ignored unsupported client payload keys=%s", sorted(live_payload.keys()))
        except ConnectionClosedError:
            logger.info("[live] client websocket closed during receive")
            self._closed = True
        except Exception as exc:
            logger.exception("[live] client->live bridge failed: %s", exc)
            await self._safe_send_json({"error": str(exc)})
            self._closed = True
        finally:
            logger.info("[live] client->live loop ended closed=%s", self._closed)

    async def _forward_live_to_client(self, session: Any) -> None:
        try:
            while not self._closed:
                async for response in session.receive():
                    if response.tool_call and response.tool_call.function_calls:
                        logger.info("[live] Gemini requested %s tool call(s)", len(response.tool_call.function_calls))
                        function_responses = [
                            await _tool_response(function_call, self.user_id)
                            for function_call in response.tool_call.function_calls
                        ]
                        await session.send_tool_response(function_responses=function_responses)
                        continue

                    payload = self._json_safe(
                        response.model_dump(by_alias=True, exclude_none=True)
                    )
                    if payload:
                        logger.info("[live] forwarding Gemini event keys=%s", sorted(payload.keys()))
                        turn_complete = self._capture_turn_from_payload(payload)
                        if not await self._safe_send_json(payload):
                            logger.info("[live] websocket send failed while forwarding Gemini event")
                            return
                        if turn_complete:
                            await self._flush_turn_updates(reason="turn_complete")

                logger.info("[live] Gemini session.receive() stream ended, restarting for next turn")
        except Exception as exc:
            logger.exception("[live] live->client bridge failed: %s", exc)
            await self._safe_send_json({"error": str(exc)})
        finally:
            try:
                await self._flush_turn_updates(reason="live_loop_end")
            except Exception:
                logger.exception("[live] failed flushing post-turn updates on shutdown")
            self._closed = True
            logger.info("[live] live->client loop ended closed=%s", self._closed)

    async def run(self) -> None:
        client = create_genai_client()
        config = await self._build_config()
        logger.info("[live] opening Gemini Live session model=%s", LIVE_MODEL)

        async with client.aio.live.connect(model=LIVE_MODEL, config=config) as session:
            logger.info("[live] Gemini Live session opened")
            if not await self._safe_send_json({"setupComplete": {}}):
                logger.info("[live] websocket closed before setupComplete could be sent")
                return

            from_client = asyncio.create_task(self._forward_client_to_live(session))
            from_model = asyncio.create_task(self._forward_live_to_client(session))

            try:
                await asyncio.gather(from_client, from_model)
            finally:
                logger.info(
                    "[live] bridge shutting down client_done=%s model_done=%s",
                    from_client.done(),
                    from_model.done(),
                )
                self._closed = True
                for task in (from_client, from_model):
                    if not task.done():
                        task.cancel()
                for task in (from_client, from_model):
                    with suppress(asyncio.CancelledError):
                        await task
