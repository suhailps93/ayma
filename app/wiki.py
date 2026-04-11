"""
Wiki layer — per-user GCS knowledge base.

Each user gets a folder: gs://{WIKI_BUCKET_NAME}/{user_id}/
Pages: about_me.md, preferences.md, context.md, media.md

The agent reads all pages at session start for rich synthesized context.
Pages are updated asynchronously after each turn by wiki_update.py.
Photos are processed by media_process.py which writes to media.md.
"""
import logging
import os
from pathlib import Path

from google.api_core import exceptions as gcs_exceptions
from google.cloud import storage

logger = logging.getLogger(__name__)

WIKI_PAGES = ["about_me.md", "preferences.md", "context.md", "media.md"]


def _bucket_name() -> str:
    return os.environ.get("WIKI_BUCKET_NAME", "").strip()


def _bucket():
    client = storage.Client()
    return client.bucket(_bucket_name())


def _local_root() -> Path:
    return Path(os.environ.get("WIKI_LOCAL_DIR", Path(__file__).resolve().parents[1] / ".wiki"))


def _local_page_path(user_id: str, page: str) -> Path:
    return _local_root() / user_id / page


def read_wiki_page(user_id: str, page: str) -> str:
    """Read a wiki page. Returns empty string if not found or on error."""
    if not _bucket_name():
        try:
            path = _local_page_path(user_id, page)
            return path.read_text() if path.exists() else ""
        except Exception as e:
            logger.warning(f"[wiki] local read {page} for {user_id} failed: {e}")
            return ""

    try:
        blob = _bucket().blob(f"{user_id}/{page}")
        return blob.download_as_text()
    except gcs_exceptions.NotFound:
        return ""
    except Exception as e:
        logger.warning(f"[wiki] read {page} for {user_id} failed: {e}")
        return ""


def write_wiki_page(user_id: str, page: str, content: str) -> None:
    """Write/overwrite a wiki page."""
    if not _bucket_name():
        path = _local_page_path(user_id, page)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        logger.info(f"[wiki] wrote local {page} for {user_id} ({len(content)} chars)")
        return

    blob = _bucket().blob(f"{user_id}/{page}")
    blob.upload_from_string(content, content_type="text/markdown")
    logger.info(f"[wiki] wrote {page} for {user_id} ({len(content)} chars)")


def read_all_wiki_pages(user_id: str) -> str:
    """Read all wiki pages and return as a formatted context block."""
    sections = []
    for page in WIKI_PAGES:
        content = read_wiki_page(user_id, page)
        if content.strip():
            title = page.replace(".md", "").replace("_", " ").title()
            sections.append(f"### {title}\n{content.strip()}")
    if not sections:
        return ""
    return "\n\n".join(sections)
