"""
/internal/generate-matches handler

Two-stage server-side match generation:
1. Stage 1: structured filtering and heuristic ranking from user_profiles + matching_prefs.
2. Stage 2: Gemini evaluates the top candidates more deeply and writes/upserts rows to matches.

This runs only on the backend. Nothing is computed on the client.
"""
import asyncio
import json
import logging
import os
from dataclasses import dataclass
from typing import Any

from google.genai import types
from supabase import create_client

from app.genai_client import create_genai_client
from app.model_config import EMBEDDING_MODEL, FAST_MODEL
from app.wiki import read_all_wiki_pages
from app.internal.notifications import create_notification

logger = logging.getLogger(__name__)

STAGE1_LIMIT = 24
STAGE2_LIMIT = 8


@dataclass
class CandidateProfile:
    id: str
    display_name: str
    age: int | None
    gender: str | None
    location_region: str | None
    matching_prefs: dict[str, Any]
    profile_public: str
    profile_private: str
    matching_paused: bool


def _supabase():
    return create_client(
        os.environ["SUPABASE_URL"],
        os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )


def _normalize_gender(value: str | None) -> str:
    if not value:
        return ""
    value = value.strip().lower()
    if value in {"male", "man", "men"}:
        return "man"
    if value in {"female", "woman", "women"}:
        return "woman"
    if value in {"non-binary", "nonbinary"}:
        return "non-binary"
    return value


def _preferred_genders(pref: str | None) -> set[str] | None:
    value = (pref or "").strip().lower()
    if not value or value == "everyone":
        return None
    if value == "men":
        return {"man"}
    if value == "women":
        return {"woman"}
    return {_normalize_gender(value)}


def _age_in_range(age: int | None, prefs: dict[str, Any]) -> bool:
    if age is None:
        return False
    low = prefs.get("age_min")
    high = prefs.get("age_max")
    if low is not None and age < int(low):
        return False
    if high is not None and age > int(high):
        return False
    return True


def _same_region(a: str | None, b: str | None) -> bool:
    if not a or not b:
        return False
    return a.strip().lower() == b.strip().lower()


def _load_profile(user_id: str) -> CandidateProfile | None:
    result = (
        _supabase().table("user_profiles")
        .select(
            "id, display_name, age, gender, location_region, matching_prefs, "
            "profile_public, profile_private, onboarding_complete, matching_paused"
        )
        .eq("id", user_id)
        .single()
        .execute()
    )
    data = result.data or {}
    if not data or not data.get("onboarding_complete"):
        return None
    return CandidateProfile(
        id=data["id"],
        display_name=data.get("display_name") or "",
        age=data.get("age"),
        gender=data.get("gender"),
        location_region=data.get("location_region"),
        matching_prefs=data.get("matching_prefs") or {},
        profile_public=data.get("profile_public") or "",
        profile_private=data.get("profile_private") or "",
        matching_paused=bool(data.get("matching_paused", False)),
    )


def _load_candidate_pool(exclude_user_id: str) -> list[CandidateProfile]:
    result = (
        _supabase().table("user_profiles")
        .select(
            "id, display_name, age, gender, location_region, matching_prefs, "
            "profile_public, profile_private, onboarding_complete, matching_paused"
        )
        .neq("id", exclude_user_id)
        .eq("onboarding_complete", True)
        .limit(500)
        .execute()
    )
    rows = result.data or []
    return [
        CandidateProfile(
            id=row["id"],
            display_name=row.get("display_name") or "",
            age=row.get("age"),
            gender=row.get("gender"),
            location_region=row.get("location_region"),
            matching_prefs=row.get("matching_prefs") or {},
            profile_public=row.get("profile_public") or "",
            profile_private=row.get("profile_private") or "",
            matching_paused=bool(row.get("matching_paused", False)),
        )
        for row in rows
    ]


def _existing_match_ids(user_id: str) -> set[str]:
    result = (
        _supabase().table("matches")
        .select("user_a, user_b")
        .or_(f"user_a.eq.{user_id},user_b.eq.{user_id}")
        .limit(500)
        .execute()
    )
    seen: set[str] = set()
    for row in result.data or []:
        a = row.get("user_a")
        b = row.get("user_b")
        if a == user_id and isinstance(b, str):
            seen.add(b)
        elif b == user_id and isinstance(a, str):
            seen.add(a)
    return seen


def _stage1_score(source: CandidateProfile, candidate: CandidateProfile) -> float | None:
    source_gender_pref = _preferred_genders(source.matching_prefs.get("interested_in"))
    candidate_gender_pref = _preferred_genders(candidate.matching_prefs.get("interested_in"))

    candidate_gender = _normalize_gender(candidate.gender)
    source_gender = _normalize_gender(source.gender)

    if source.matching_paused or candidate.matching_paused:
        return None

    if source_gender_pref is not None and candidate_gender not in source_gender_pref:
        return None
    if candidate_gender_pref is not None and source_gender not in candidate_gender_pref:
        return None

    if not _age_in_range(candidate.age, source.matching_prefs):
        return None
    if not _age_in_range(source.age, candidate.matching_prefs):
        return None

    score = 0.0
    score += 0.35
    score += 0.20
    score += 0.15

    if _same_region(source.location_region, candidate.location_region):
        score += 0.10
    if source.profile_public.strip() and candidate.profile_public.strip():
        score += 0.08
    if source.profile_private.strip() and candidate.profile_private.strip():
        score += 0.04
    if candidate.age is not None and source.age is not None:
        gap = abs(candidate.age - source.age)
        score += max(0.0, 0.08 - (gap / 100.0))

    return round(min(score, 0.99), 4)


def _ordered_pair(a: str, b: str) -> tuple[str, str]:
    return (a, b) if a < b else (b, a)


def _json_from_text(text: str) -> dict[str, Any]:
    raw = text.strip()
    if raw.startswith("```"):
        raw = raw.split("```", 2)[1]
        if raw.startswith("json"):
            raw = raw[4:]
    return json.loads(raw.strip())


def _safe_list(value: Any, limit: int = 4) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str) and item.strip():
            out.append(item.strip())
        if len(out) >= limit:
            break
    return out


def _photo_similarity_boosts(source: CandidateProfile) -> dict[str, float]:
    try:
        query_text = (
            f"dating match preferences: interested_in={source.matching_prefs.get('interested_in')} "
            f"age_min={source.matching_prefs.get('age_min')} age_max={source.matching_prefs.get('age_max')} "
            f"profile={source.profile_public} wiki={read_all_wiki_pages(source.id)}"
        )
        gc = create_genai_client()
        emb = gc.models.embed_content(
            model=EMBEDDING_MODEL,
            contents=query_text,
            config=types.EmbedContentConfig(output_dimensionality=768),
        )
        vec = emb.embeddings[0].values
        vec_str = '[' + ','.join(str(v) for v in vec) + ']'
        result = _supabase().rpc('match_user_photos', {
            'query_embedding': vec_str,
            'exclude_user_id': source.id,
            'match_count': STAGE1_LIMIT,
        }).execute()
        boosts: dict[str, float] = {}
        for row in result.data or []:
            uid = row.get('user_id')
            sim = row.get('similarity')
            if isinstance(uid, str) and isinstance(sim, (int, float)):
                boosts[uid] = max(boosts.get(uid, 0.0), float(sim))
        return boosts
    except Exception as exc:
        logger.warning('[match] photo boost lookup failed for %s: %s', source.id, exc)
        return {}


def _profile_context(profile: CandidateProfile) -> str:
    wiki = read_all_wiki_pages(profile.id)
    return (
        f"Display name: {profile.display_name or 'Unknown'}\n"
        f"Age: {profile.age if profile.age is not None else 'Unknown'}\n"
        f"Gender: {profile.gender or 'Unknown'}\n"
        f"Location: {profile.location_region or 'Unknown'}\n"
        f"Matching prefs: {json.dumps(profile.matching_prefs, ensure_ascii=True)}\n"
        f"Public profile:\n{profile.profile_public or '(empty)'}\n\n"
        f"Private profile:\n{profile.profile_private or '(empty)'}\n\n"
        f"Wiki:\n{wiki or '(empty)'}"
    )


MATCH_PROMPT = """You are Ayma's backend match evaluator. Assess compatibility between two users.

You may use private context for scoring, but any user-visible text must not reveal sensitive details, hidden memories,
or anything one user did not explicitly share publicly. Keep rationales warm, concise, and privacy-safe.

Return strict JSON with this schema:
{
  "score": 0.0,
  "commonalities": ["..."],
  "differences": ["..."],
  "rationale": "2-3 sentence public-safe rationale",
  "summary_a": "Short summary tailored for user A only",
  "summary_b": "Short summary tailored for user B only"
}

User A:
{source}

User B:
{candidate}
"""


async def _stage2_match(source: CandidateProfile, candidate: CandidateProfile) -> dict[str, Any] | None:
    client = create_genai_client()
    response = await client.aio.models.generate_content(
        model=FAST_MODEL,
        contents=MATCH_PROMPT.format(
            source=_profile_context(source),
            candidate=_profile_context(candidate),
        ),
        config=types.GenerateContentConfig(
            temperature=0.2,
            response_mime_type="application/json",
        ),
    )
    try:
        return _json_from_text(response.text or "")
    except Exception as exc:
        logger.warning("[match] failed to parse stage2 result %s -> %s", candidate.id, exc)
        return None


async def handle_match_generation(user_id: str) -> dict[str, Any]:
    source = _load_profile(user_id)
    if source is None:
        return {"status": "skipped", "reason": "source profile missing or onboarding incomplete"}

    existing = _existing_match_ids(user_id)
    photo_boosts = _photo_similarity_boosts(source)
    stage1: list[tuple[float, CandidateProfile]] = []
    for candidate in _load_candidate_pool(user_id):
        if candidate.id in existing:
            continue
        score = _stage1_score(source, candidate)
        if score is None:
            continue
        if candidate.id in photo_boosts:
            score = min(0.99, score + max(0.0, min(0.12, photo_boosts[candidate.id] * 0.12)))
        stage1.append((score, candidate))

    stage1.sort(key=lambda item: item[0], reverse=True)
    shortlisted = [candidate for _, candidate in stage1[:STAGE1_LIMIT]]
    if not shortlisted:
        return {"status": "ok", "stage1_candidates": 0, "stage2_matches": 0}

    sem = asyncio.Semaphore(4)

    async def _run(candidate: CandidateProfile) -> tuple[CandidateProfile, dict[str, Any] | None]:
        async with sem:
            return candidate, await _stage2_match(source, candidate)

    stage2_results = await asyncio.gather(*[_run(candidate) for candidate in shortlisted[:STAGE2_LIMIT]])

    supabase = _supabase()
    writes = 0
    for stage1_score, candidate in stage1[:STAGE2_LIMIT]:
        result = next((payload for cand, payload in stage2_results if cand.id == candidate.id), None)
        if not result:
            continue

        ai_score = result.get("score")
        try:
            ai_score = float(ai_score)
        except Exception:
            ai_score = stage1_score
        final_score = max(0.0, min(1.0, round((stage1_score * 0.35) + (ai_score * 0.65), 4)))
        if final_score < 0.45:
            continue

        user_a, user_b = _ordered_pair(source.id, candidate.id)
        payload = {
            "user_a": user_a,
            "user_b": user_b,
            "score": final_score,
            "commonalities": _safe_list(result.get("commonalities")),
            "differences": _safe_list(result.get("differences")),
            "rationale": (result.get("rationale") or "").strip(),
            "summary_a": (result.get("summary_a") or "").strip(),
            "summary_b": (result.get("summary_b") or "").strip(),
            "status": "shown",
        }
        supabase.table("matches").upsert(payload, on_conflict="user_a,user_b").execute()
        try:
            other_name = candidate.display_name or "someone new"
            create_notification(source.id, notif_type="new_match", title="New match", body=f"Ayma found a promising match with {other_name}.", meta={"match_user_id": candidate.id})
            source_name = source.display_name or "someone new"
            create_notification(candidate.id, notif_type="new_match", title="New match", body=f"Ayma found a promising match with {source_name}.", meta={"match_user_id": source.id})
        except Exception:
            pass
        writes += 1

    logger.info("[match] generated matches for user=%s stage1=%s stage2=%s writes=%s", user_id, len(stage1), min(len(shortlisted), STAGE2_LIMIT), writes)
    return {
        "status": "ok",
        "stage1_candidates": len(stage1),
        "stage2_matches": writes,
    }
