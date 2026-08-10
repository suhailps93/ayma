from __future__ import annotations

import logging
from collections.abc import Iterable

from firebase_admin import firestore, initialize_app
from firebase_functions import firestore_fn
import google.cloud.firestore
from google.cloud.firestore_v1.base_query import FieldFilter

app = initialize_app()

logger = logging.getLogger(__name__)

MAX_BATCH_OPERATIONS = 400
USER_SUBCOLLECTIONS = (
    "notifications",
    "user_media",
    "user_memories",
    "user_questions",
    "user_skills",
)


def _delete_refs_in_batches(
    db: google.cloud.firestore.Client,
    refs: Iterable[google.cloud.firestore.DocumentReference],
) -> int:
    batch = db.batch()
    pending = 0
    deleted = 0

    for ref in refs:
        batch.delete(ref)
        pending += 1
        deleted += 1
        if pending >= MAX_BATCH_OPERATIONS:
            batch.commit()
            batch = db.batch()
            pending = 0

    if pending:
        batch.commit()

    return deleted


def _delete_collection(
    db: google.cloud.firestore.Client,
    collection: google.cloud.firestore.CollectionReference,
) -> int:
    refs = (snapshot.reference for snapshot in collection.stream())
    return _delete_refs_in_batches(db, refs)


def _get_match_pair_ids(
    db: google.cloud.firestore.Client,
    uid: str,
) -> list[str]:
    seen: set[str] = set()
    pair_ids: list[str] = []

    query_a = db.collection("matches").where(filter=FieldFilter("user_a", "==", uid))
    for snapshot in query_a.stream():
        if snapshot.id in seen:
            continue
        seen.add(snapshot.id)
        pair_ids.append(snapshot.id)

    query_b = db.collection("matches").where(filter=FieldFilter("user_b", "==", uid))
    for snapshot in query_b.stream():
        if snapshot.id in seen:
            continue
        seen.add(snapshot.id)
        pair_ids.append(snapshot.id)

    return pair_ids


# Firestore/event-driven functions do not retry on failure unless retry is
# explicitly enabled, so letting exceptions surface is simpler and keeps
# partial-cleanup bugs visible in Cloud Logging/Error Reporting.
@firestore_fn.on_document_deleted(document="users/{uid}")
def cleanup_deleted_user(
    event: firestore_fn.Event[firestore_fn.DocumentSnapshot | None],
) -> None:
    uid = event.params["uid"]
    db: google.cloud.firestore.Client = firestore.client()

    user_subdoc_count = 0
    simulations_deleted = 0
    match_docs_deleted = 0
    message_docs_deleted = 0
    conversation_delete_attempts = 0

    user_ref = db.collection("users").document(uid)
    for subcollection_name in USER_SUBCOLLECTIONS:
        user_subdoc_count += _delete_collection(
            db,
            user_ref.collection(subcollection_name),
        )

    pair_ids = _get_match_pair_ids(db, uid)

    for pair_id in pair_ids:
        match_ref = db.collection("matches").document(pair_id)
        simulations_deleted += _delete_collection(db, match_ref.collection("simulations"))
        match_docs_deleted += _delete_refs_in_batches(db, [match_ref])

    for pair_id in pair_ids:
        conversation_ref = db.collection("conversations").document(pair_id)
        message_docs_deleted += _delete_collection(db, conversation_ref.collection("messages"))
        conversation_delete_attempts += _delete_refs_in_batches(db, [conversation_ref])

    logger.info(
        "cleanup_deleted_user completed",
        extra={
            "uid": uid,
            "user_subdocs_deleted": user_subdoc_count,
            "matched_pairs": len(pair_ids),
            "simulation_docs_deleted": simulations_deleted,
            "match_docs_deleted": match_docs_deleted,
            "message_docs_deleted": message_docs_deleted,
            "conversation_delete_attempts": conversation_delete_attempts,
        },
    )
