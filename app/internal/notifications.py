import os
from typing import Any

from supabase import create_client


def _supabase():
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )


def create_notification(
    user_id: str,
    *,
    notif_type: str,
    title: str,
    body: str,
    meta: dict[str, Any] | None = None,
) -> None:
    _supabase().table("notifications").insert({
        "user_id": user_id,
        "type": notif_type,
        "title": title,
        "body": body,
        "meta": meta or {},
    }).execute()
