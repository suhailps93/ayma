"""
⚠️  DO NOT EDIT without explicit instruction from the product owner.
    This is the single source of truth for all tuneable constants.
    No agent should modify this file autonomously.

Central configuration for the Ayma bootstrap service.

All tuneable values live here. Environment variables override defaults.
Hardcoding any of these values elsewhere in main.py is not allowed.
"""

import os


def _require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value

# ── Firebase / GCP ────────────────────────────────────────────────────────────

FIREBASE_PROJECT_ID: str = os.environ.get("FIREBASE_PROJECT_ID", "ayma-ai")

GOOGLE_API_KEY: str = _require_env("GOOGLE_API_KEY")

# ── Gemini models ─────────────────────────────────────────────────────────────

# Voice — Gemini Live WebSocket (bidirectional audio)
LIVE_MODEL: str = os.environ.get("LIVE_MODEL", "gemini-3.1-flash-live-preview")

# Text — chat replies, post-turn extraction, scoring, photo analysis, safety
TEXT_MODEL: str = os.environ.get("TEXT_MODEL", "gemini-3.5-flash")

# Embeddings — semantic memory retrieval (Step 7)
EMBEDDING_MODEL: str = os.environ.get("EMBEDDING_MODEL", "gemini-embedding-2")

# ── Rate limits (slowapi, per IP) ─────────────────────────────────────────────

RATE_BOOTSTRAP:      str = os.environ.get("RATE_BOOTSTRAP",      "10/minute")
RATE_POST_TURN:      str = os.environ.get("RATE_POST_TURN",      "30/minute")
RATE_CHAT_TEXT:      str = os.environ.get("RATE_CHAT_TEXT",      "20/minute")
RATE_ANALYZE_PHOTOS: str = os.environ.get("RATE_ANALYZE_PHOTOS", "5/minute")
RATE_RUN_MATCHING:   str = os.environ.get("RATE_RUN_MATCHING",   "3/minute")

# ── Matching engine thresholds ────────────────────────────────────────────────

# Minimum Gemini compatibility score to write a match row (0–1)
MATCH_SCORE_MIN: float = float(os.environ.get("MATCH_SCORE_MIN", "0.4"))

# Minimum score to run a full vibe-check simulation on top of scoring
VIBE_CHECK_THRESHOLD: float = float(os.environ.get("VIBE_CHECK_THRESHOLD", "0.65"))

# Max candidates fetched before heuristic filter
MATCH_CANDIDATE_POOL: int = int(os.environ.get("MATCH_CANDIDATE_POOL", "100"))

# Max candidates sent to Gemini scoring after heuristic filter
MATCH_SCORE_TOP_K: int = int(os.environ.get("MATCH_SCORE_TOP_K", "15"))

# Max pairs sent for vibe-check after scoring
VIBE_CHECK_TOP_K: int = int(os.environ.get("VIBE_CHECK_TOP_K", "5"))

# Cron matching: candidate pool per user (lighter than full run-matching)
CRON_CANDIDATE_POOL: int = int(os.environ.get("CRON_CANDIDATE_POOL", "50"))
CRON_SCORE_TOP_K:    int = int(os.environ.get("CRON_SCORE_TOP_K",    "10"))

# Final score blend: compatibility × weight + synergy × (1 − weight)
FINAL_SCORE_COMPAT_WEIGHT: float = float(os.environ.get("FINAL_SCORE_COMPAT_WEIGHT", "0.7"))

# ── Query limits ──────────────────────────────────────────────────────────────

MESSAGES_LIMIT:       int = int(os.environ.get("MESSAGES_LIMIT",       "200"))
NOTIFICATIONS_LIMIT:  int = int(os.environ.get("NOTIFICATIONS_LIMIT",  "50"))
EXPLORE_LIMIT:        int = int(os.environ.get("EXPLORE_LIMIT",         "50"))
INSIGHTS_MEDIA_LIMIT: int = int(os.environ.get("INSIGHTS_MEDIA_LIMIT",  "20"))
MATCHES_MEDIA_LIMIT:  int = int(os.environ.get("MATCHES_MEDIA_LIMIT",   "24"))
PHOTO_ANALYSIS_MAX:   int = int(os.environ.get("PHOTO_ANALYSIS_MAX",     "3"))

# ── Notifications ─────────────────────────────────────────────────────────────

# Max characters from a DM body to include in the push notification preview
PUSH_PREVIEW_LEN: int = int(os.environ.get("PUSH_PREVIEW_LEN", "100"))

# ── Cron / system access ──────────────────────────────────────────────────────

# Set this in Cloud Run env vars and in Cloud Scheduler HTTP header X-Cron-Secret
CRON_SECRET: str = os.environ.get("CRON_SECRET", "")

# Admin password for admin dashboard endpoints
ADMIN_PASSWORD: str = os.environ.get("ADMIN_PASSWORD", "")

# App Check — monitor mode logs failures; set APP_CHECK_ENFORCE=true to reject
APP_CHECK_ENFORCE: bool = os.environ.get("APP_CHECK_ENFORCE", "false").lower() in (
    "1",
    "true",
    "yes",
)
