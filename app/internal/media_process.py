"""
/internal/process-photo handler

Called when a user uploads a photo. Does four things:
1. Downloads image bytes from GCS
2. Gemini Flash generates a human-readable caption
3. Embedding 2 embeds image + caption together → 768-dim vector → user_media table
4. Appends entry to user's media.md wiki page

The multimodal embedding puts photos and text in the same vector space,
enabling cross-modal matching: "find someone who looks creative and warm" → finds photos.
"""
import logging
import os
from datetime import datetime, timezone
from pathlib import Path

from google.cloud import storage
from google.genai import types
from supabase import create_client

from app.genai_client import create_genai_client
from app.model_config import EMBEDDING_MODEL, FAST_MODEL
from app.wiki import read_wiki_page, write_wiki_page

logger = logging.getLogger(__name__)

EMBEDDING_DIMS = 768

IMAGE_CAPTION_PROMPT = (
    "Describe this person in their dating profile media. "
    "Focus on: overall vibe, style, setting, expression, energy. "
    "2-3 sentences. Be warm and specific."
)

VIDEO_CAPTION_PROMPT = (
    "Describe this dating profile video. Focus on what the person is like, their energy, setting, style, and what the clip communicates about them. "
    "2-4 sentences. Be warm and specific."
)


def _clients():
    gc = create_genai_client()
    supabase = create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )
    return gc, supabase


def _guess_mime(path: str) -> str:
    ext = path.rsplit(".", 1)[-1].lower()
    mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "mp4": "video/mp4", "mov": "video/quicktime"}.get(
        ext, "application/octet-stream"
    )
    return mime


def _load_media_bytes(media_uri: str) -> tuple[bytes, str]:
    """Load bytes from either gs:// or a local absolute file path."""
    if media_uri.startswith("gs://"):
        path = media_uri.removeprefix("gs://")
        bucket_name, blob_path = path.split("/", 1)
        gcs_client = storage.Client()
        data = gcs_client.bucket(bucket_name).blob(blob_path).download_as_bytes()
        return data, _guess_mime(blob_path)

    path = Path(media_uri)
    data = path.read_bytes()
    return data, _guess_mime(path.name)


async def _caption(media_bytes: bytes, mime_type: str) -> str:
    client = create_genai_client()
    prompt = VIDEO_CAPTION_PROMPT if mime_type.startswith("video/") else IMAGE_CAPTION_PROMPT
    response = await client.aio.models.generate_content(
        model=FAST_MODEL,
        contents=types.Content(
            role="user",
            parts=[
                types.Part.from_bytes(data=media_bytes, mime_type=mime_type),
                types.Part.from_text(prompt),
            ],
        ),
    )
    return (response.text or "").strip()


def _embed(
    gc,
    image_bytes: bytes,
    mime_type: str,
    caption: str,
) -> list[float]:
    """Embed photo + caption together into a single 768-dim vector."""
    result = gc.models.embed_content(
        model=EMBEDDING_MODEL,
        contents=types.Content(parts=[
            types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
            types.Part.from_text(f"task: search result | query: {caption}"),
        ]),
        config=types.EmbedContentConfig(output_dimensionality=EMBEDDING_DIMS),
    )
    return result.embeddings[0].values


def _update_media_wiki(user_id: str, media_url: str, caption: str, media_type: str) -> None:
    current = read_wiki_page(user_id, "media.md")
    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    label = "Photo" if media_type == "image" else "Video"
    entry = f"- [{date}] {label}: {media_url}\n  {caption}"
    updated = (
        f"{current.strip()}\n\n{entry}" if current.strip() else f"# Media\n\n{entry}"
    )
    write_wiki_page(user_id, "media.md", updated)


async def handle_media_process(user_id: str, photo_url: str) -> dict:
    """Caption → optional embed → store → update wiki. Returns caption and embedding dims."""
    gc, supabase = _clients()

    media_bytes, mime_type = _load_media_bytes(photo_url)
    media_type = "video" if mime_type.startswith("video/") else "image"
    caption = await _caption(media_bytes, mime_type)
    logger.info(f"[media] {user_id}: {caption[:80]}")

    embedding: list[float] = []
    vec_str = None
    if media_type == "image":
        embedding = _embed(gc, media_bytes, mime_type, caption)
        vec_str = "[" + ",".join(str(v) for v in embedding) + "]"

    supabase.table("user_media").insert({
        "user_id": user_id,
        "photo_url": photo_url,
        "caption": caption,
        "embedding": vec_str,
        "media_type": media_type,
    }).execute()

    _update_media_wiki(user_id, photo_url, caption, media_type)

    return {"caption": caption, "dims": len(embedding), "media_type": media_type}
