import asyncio
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path
import re


def _install_test_stubs():
    os.environ.setdefault("GOOGLE_API_KEY", "test-key")

    asyncpg = types.ModuleType("asyncpg")

    async def _create_pool(*args, **kwargs):
        return None

    asyncpg.create_pool = _create_pool
    sys.modules["asyncpg"] = asyncpg

    firebase_admin = types.ModuleType("firebase_admin")
    firebase_admin._apps = []
    firebase_admin.initialize_app = lambda **kwargs: None

    auth_module = types.ModuleType("firebase_admin.auth")
    auth_module.verify_id_token = lambda token: {"uid": "test-uid"}
    auth_module.get_user = lambda uid: types.SimpleNamespace(display_name="Test User")
    messaging_module = types.ModuleType("firebase_admin.messaging")
    messaging_module.Message = lambda **kwargs: types.SimpleNamespace(**kwargs)
    messaging_module.Notification = lambda **kwargs: types.SimpleNamespace(**kwargs)
    messaging_module.AndroidConfig = lambda **kwargs: types.SimpleNamespace(**kwargs)
    messaging_module.APNSConfig = lambda **kwargs: types.SimpleNamespace(**kwargs)
    messaging_module.APNSPayload = lambda **kwargs: types.SimpleNamespace(**kwargs)
    messaging_module.Aps = lambda **kwargs: types.SimpleNamespace(**kwargs)
    messaging_module.send = lambda msg: "ok"
    firebase_admin.auth = auth_module
    firebase_admin.messaging = messaging_module
    sys.modules["firebase_admin"] = firebase_admin
    sys.modules["firebase_admin.auth"] = auth_module
    sys.modules["firebase_admin.messaging"] = messaging_module

    genai = types.ModuleType("google.generativeai")
    genai.configure = lambda **kwargs: None

    class _DummyGenerativeModel:
        def __init__(self, *args, **kwargs):
            pass

        async def generate_content_async(self, *args, **kwargs):
            return types.SimpleNamespace(text="{}")

    genai.GenerativeModel = _DummyGenerativeModel
    google_pkg = types.ModuleType("google")
    google_pkg.generativeai = genai
    google_genai = types.ModuleType("google.genai")

    class _DummyEmbedContentConfig:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    class _DummyEmbeddingClient:
        def __init__(self, *args, **kwargs):
            self.models = types.SimpleNamespace(
                embed_content=lambda **kwargs: types.SimpleNamespace(
                    embeddings=[types.SimpleNamespace(values=[0.1, 0.2])]
                )
            )

    google_genai.Client = _DummyEmbeddingClient
    google_genai_types = types.ModuleType("google.genai.types")
    google_genai_types.EmbedContentConfig = _DummyEmbedContentConfig
    sys.modules["google"] = google_pkg
    sys.modules["google.generativeai"] = genai
    sys.modules["google.genai"] = google_genai
    sys.modules["google.genai.types"] = google_genai_types

    fastapi = types.ModuleType("fastapi")

    class HTTPException(Exception):
        def __init__(self, status_code=500, detail=""):
            self.status_code = status_code
            self.detail = detail
            super().__init__(detail)

    class FastAPI:
        def __init__(self, *args, **kwargs):
            self.state = types.SimpleNamespace()

        def get(self, *args, **kwargs):
            return lambda fn: fn

        def post(self, *args, **kwargs):
            return lambda fn: fn

        def delete(self, *args, **kwargs):
            return lambda fn: fn

        def add_exception_handler(self, *args, **kwargs):
            return None

        def add_middleware(self, *args, **kwargs):
            return None

    fastapi.Depends = lambda x: x
    fastapi.FastAPI = FastAPI
    fastapi.Header = lambda default=None, **kwargs: default
    fastapi.HTTPException = HTTPException
    fastapi.Request = type("Request", (), {})
    sys.modules["fastapi"] = fastapi

    cors_module = types.ModuleType("fastapi.middleware.cors")
    cors_module.CORSMiddleware = type("CORSMiddleware", (), {})
    sys.modules["fastapi.middleware.cors"] = cors_module

    security_module = types.ModuleType("fastapi.security")

    class HTTPAuthorizationCredentials:
        def __init__(self, credentials="token"):
            self.credentials = credentials

    class HTTPBearer:
        def __call__(self):
            return None

    security_module.HTTPAuthorizationCredentials = HTTPAuthorizationCredentials
    security_module.HTTPBearer = HTTPBearer
    sys.modules["fastapi.security"] = security_module

    slowapi = types.ModuleType("slowapi")

    class _Limiter:
        def __init__(self, *args, **kwargs):
            pass

        def limit(self, *args, **kwargs):
            return lambda fn: fn

    slowapi.Limiter = _Limiter
    slowapi._rate_limit_exceeded_handler = lambda *args, **kwargs: None
    sys.modules["slowapi"] = slowapi

    slowapi_errors = types.ModuleType("slowapi.errors")
    slowapi_errors.RateLimitExceeded = type("RateLimitExceeded", (Exception,), {})
    sys.modules["slowapi.errors"] = slowapi_errors

    slowapi_util = types.ModuleType("slowapi.util")
    slowapi_util.get_remote_address = lambda *args, **kwargs: "127.0.0.1"
    sys.modules["slowapi.util"] = slowapi_util

    pydantic = types.ModuleType("pydantic")

    class BaseModel:
        def __init__(self, **kwargs):
            for key, value in kwargs.items():
                setattr(self, key, value)

        def model_dump(self, exclude_unset=False):
            return dict(self.__dict__)

    pydantic.BaseModel = BaseModel
    sys.modules["pydantic"] = pydantic


def _load_module(name: str, relative_path: str):
    path = Path(__file__).resolve().parent / relative_path
    parent = str(path.parent)
    if parent not in sys.path:
        sys.path.insert(0, parent)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


_install_test_stubs()
bootstrap_main = _load_module("bootstrap_main_under_test", "main.py")
mock_db = _load_module("bootstrap_mock_db_under_test", "mock_db.py")


def _parse_flutter_community_profiles():
    path = Path(__file__).resolve().parents[2] / "ayma_flutter" / "lib" / "models" / "community_profile.dart"
    text = path.read_text()
    profiles = {}
    block_pattern = re.compile(
        r"static const \w+ = CommunityProfile\((.*?)\n  \);",
        re.DOTALL,
    )
    for block in block_pattern.findall(text):
        id_match = re.search(r"id:\s*'([^']+)'", block)
        ids_match = re.search(r"questionIds:\s*\[(.*?)\]", block, re.DOTALL)
        if not id_match or not ids_match:
            continue
        community_id = id_match.group(1)
        question_ids = re.findall(r"'([^']+)'", ids_match.group(1))
        profiles[community_id] = question_ids
    return profiles


class BootstrapLogicTests(unittest.TestCase):
    def test_answered_keys_include_onboarding_backed_fields(self):
        profile = {
            "age": 28,
            "gender": "woman",
            "location_region": "San Francisco, CA",
            "matching_prefs": {"age_min": 24, "age_max": 35},
            "profile_answers": {"relationship_intent": "long_term"},
        }

        answered = bootstrap_main._answered_question_keys_from_profile(profile)

        self.assertIn("age", answered)
        self.assertIn("gender_identity", answered)
        self.assertIn("location_city", answered)
        self.assertIn("preferred_age_range", answered)
        self.assertIn("relationship_intent", answered)

    def test_active_questions_follow_selected_community(self):
        profile = {"community_profile": "matrimonial_muslim"}
        questions = bootstrap_main._active_questions_for_profile(profile)
        ids = [q["id"] for q in questions]

        self.assertIn("nikah_type", ids)
        self.assertIn("halal_diet_strict", ids)
        self.assertNotIn("mother_tongue", ids)

    def test_system_prompt_includes_community_personality(self):
        profile = {
            "display_name": "Amina",
            "community_profile": "matrimonial_muslim",
            "matching_prefs": {},
            "profile_answers": {},
        }

        prompt = bootstrap_main._build_system_prompt(profile, [], [])

        self.assertIn("Community: Muslim Matrimonial", prompt)
        self.assertIn("nikah-focused", prompt)

    def test_backend_community_config_matches_flutter_profiles(self):
        flutter_profiles = _parse_flutter_community_profiles()

        for community_id, config in bootstrap_main.COMMUNITY_CONFIG.items():
            self.assertIn(community_id, flutter_profiles)
            self.assertEqual(
                config["question_ids"],
                flutter_profiles[community_id],
                f"Question IDs drifted for {community_id}",
            )

    def test_parse_row_decodes_location_coords_and_photo_order(self):
        row = {
            "matching_prefs": '{"age_min": 24, "age_max": 35}',
            "profile_answers": '{"age": 28}',
            "profile_answers_public": "{}",
            "profile_answers_private": "{}",
            "profile_answers_sensitive": "{}",
            "profile_field_visibility": "{}",
            "photo_order": '["a.jpg", "b.jpg"]',
            "voice_settings": '{"voice_gender":"female"}',
            "location_coords": '{"lat": 37.7, "lng": -122.4}',
            "onboarding_complete": 1,
            "matching_paused": 0,
            "preboarding_seen": 1,
            "profile_public_locked": 0,
            "profile_public_user_edited": 1,
            "show_simulation_transcript": 0,
        }

        parsed = bootstrap_main._parse_row(row)

        self.assertEqual(parsed["location_coords"]["lat"], 37.7)
        self.assertEqual(parsed["photo_order"], ["a.jpg", "b.jpg"])
        self.assertTrue(parsed["onboarding_complete"])
        self.assertFalse(parsed["matching_paused"])


class MockDbTests(unittest.TestCase):
    def test_mock_db_supports_location_coords_and_executemany(self):
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()

                async with pool.acquire() as conn:
                    await conn.executemany(
                        "INSERT INTO user_questions (user_id, question_id, key, text, category, is_followup, sort_order) VALUES ($1, $2, $3, $4, $5, $6, $7)",
                        [
                            ("u1", "q1", "q1", "Question 1", "required", 0, 1),
                            ("u1", "q2", "q2", "Question 2", "deeper", 0, 2),
                        ],
                    )
                    await conn.execute(
                        "INSERT INTO users (id, display_name, location_coords) VALUES ($1, $2, $3)",
                        "u1",
                        "User 1",
                        '{"lat": 1.23, "lng": 4.56}',
                    )

                raw = sqlite3.connect(db_path)
                try:
                    count = raw.execute("SELECT COUNT(*) FROM user_questions").fetchone()[0]
                    coords = raw.execute("SELECT location_coords FROM users WHERE id = 'u1'").fetchone()[0]
                finally:
                    raw.close()

                self.assertEqual(count, 2)
                self.assertIn('"lat": 1.23', coords)

        asyncio.run(_run())

    def test_profile_update_creates_missing_user_row(self):
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()
                bootstrap_main.app.state.pool = pool

                body = bootstrap_main.ProfileUpdateBody(
                    display_name="Suhail",
                    gender="man",
                    onboarding_complete=True,
                    preboarding_seen=True,
                    matching_prefs={"interested_in": "women", "age_min": 24, "age_max": 38},
                    location_coords={"lat": 37.77, "lng": -122.42},
                )

                result = await bootstrap_main.update_profile(body, uid="new-user")

                self.assertEqual(result, {"success": True})

                raw = sqlite3.connect(db_path)
                try:
                    row = raw.execute(
                        """
                        SELECT display_name, gender, onboarding_complete, preboarding_seen,
                               matching_prefs, location_coords
                        FROM users WHERE id = 'new-user'
                        """
                    ).fetchone()
                finally:
                    raw.close()

                self.assertIsNotNone(row)
                self.assertEqual(row[0], "Suhail")
                self.assertEqual(row[1], "man")
                self.assertEqual(row[2], 1)
                self.assertEqual(row[3], 1)
                self.assertIn('"interested_in": "women"', row[4])
                self.assertIn('"lat": 37.77', row[5])

        asyncio.run(_run())


class SystemPromptTests(unittest.TestCase):
    """Verify that system prompt construction is correct for new vs returning users."""

    def _new_user_profile(self):
        return {
            "display_name": "Priya",
            "age": 28,
            "gender": "Female",
            "location_region": "Toronto, Canada",
            "community_profile": "arranged_india",
        }

    def _returning_user_profile(self):
        return {
            "display_name": "Priya",
            "age": 28,
            "gender": "Female",
            "location_region": "Toronto, Canada",
            "community_profile": "arranged_india",
            "wiki_about_me": "- She is 28 years old\n- She is a software engineer at a fintech startup",
            "wiki_preferences": "- She wants someone South Indian, ideally\n- She wants someone career-stable",
        }

    def test_new_user_gets_listen_skill_not_recall_skill(self):
        """New users must get the 'first conversation' skill, not the returning-user recall skill."""
        prompt = bootstrap_main._build_system_prompt(self._new_user_profile(), [], [])
        self.assertIn("This Is Your First Conversation", prompt,
            "New user should see NEW_USER_LISTEN_SKILL")
        self.assertNotIn("Deep Recall", prompt,
            "New user must NOT see returning-user DEEP_RECALL_SKILL")

    def test_new_user_prompt_forbids_fake_memory_phrases(self):
        """New user prompt must explicitly instruct against 'good to hear from you' type phrases."""
        prompt = bootstrap_main._build_system_prompt(self._new_user_profile(), [], [])
        self.assertIn("good to hear from you", prompt.lower(),
            "The NEW_USER_LISTEN_SKILL must explicitly ban this phrase")
        # The ban must be expressed as a DO NOT rule
        ban_idx = prompt.lower().find("do not say")
        good_to_hear_idx = prompt.lower().find("good to hear from you")
        self.assertGreater(good_to_hear_idx, 0)
        # The phrase appears in the instruction (as something to avoid)
        self.assertTrue(
            "do not" in prompt[max(0, good_to_hear_idx-50):good_to_hear_idx].lower() or
            "not say" in prompt[max(0, good_to_hear_idx-50):good_to_hear_idx].lower() or
            "do not say" in prompt.lower(),
            "NEW_USER_LISTEN_SKILL must ban 'good to hear from you'"
        )

    def test_new_user_prompt_forbids_inventing_facts(self):
        """New user prompt must explicitly prohibit fabricating facts."""
        prompt = bootstrap_main._build_system_prompt(self._new_user_profile(), [], [])
        self.assertIn("invent", prompt.lower(),
            "Must contain anti-hallucination rule")

    def test_returning_user_gets_recall_skill(self):
        """Users with wiki data should get the Deep Recall skill."""
        prompt = bootstrap_main._build_system_prompt(self._returning_user_profile(), [], [])
        self.assertIn("Deep Recall", prompt)
        self.assertNotIn("This Is Your First Conversation", prompt)

    def test_returning_user_prompt_contains_wiki_data(self):
        """Returning user's wiki facts must appear in the system prompt."""
        prompt = bootstrap_main._build_system_prompt(self._returning_user_profile(), [], [])
        self.assertIn("software engineer at a fintech startup", prompt)
        self.assertIn("South Indian, ideally", prompt)

    def test_returning_user_opener_instructs_memory_callback(self):
        """Returning user opener should tell Ayma to greet warmly and reference past info."""
        prompt = bootstrap_main._build_system_prompt(self._returning_user_profile(), [], [])
        self.assertIn("greet them warmly", prompt.lower())
        self.assertIn("Priya", prompt)

    def test_no_repeated_questions_when_profile_already_answered(self):
        """Questions the user already answered must not appear in the pending questionnaire."""
        profile = {
            "display_name": "Priya",
            "age": 28,
            "gender": "Female",
            "location_region": "Toronto, Canada",
            "community_profile": "arranged_india",
            "profile_answers": {"relationship_intent": "marriage"},
        }
        all_questions = bootstrap_main._active_questions_for_profile(profile)
        answered_keys = bootstrap_main._answered_question_keys_from_profile(profile)
        pending = [q for q in all_questions if q.get("key") not in answered_keys]
        pending_keys = {q.get("key") for q in pending}

        # These are answered via profile fields — must NOT be in pending
        self.assertNotIn("age", pending_keys,
            "Age already known from profile — should not be in questionnaire")
        self.assertNotIn("gender_identity", pending_keys,
            "Gender already known from profile")
        self.assertNotIn("location_city", pending_keys,
            "Location already known from profile")
        self.assertNotIn("relationship_intent", pending_keys,
            "relationship_intent was answered in profile_answers")

    def test_anti_repetition_rule_in_matchmaker_skill(self):
        """MATCHMAKER_SKILL must contain the anti-repetition instruction."""
        # The rule should appear for any profile (new or returning)
        for profile in [self._new_user_profile(), self._returning_user_profile()]:
            prompt = bootstrap_main._build_system_prompt(profile, [], [])
            self.assertIn("Anti-repetition rule", prompt,
                "Anti-repetition rule must always be in the system prompt")
            self.assertIn("Strict factual grounding", prompt,
                "Factual grounding rule must always be in the system prompt")

    def test_community_aware_prompt_arranged_india(self):
        """arranged_india community should include horoscope/family context."""
        profile = self._new_user_profile()
        prompt = bootstrap_main._build_system_prompt(profile, [], [])
        self.assertIn("Community: Indian Arranged", prompt)

    def test_community_aware_prompt_matrimonial_muslim(self):
        """matrimonial_muslim community should include nikah context."""
        profile = {
            "display_name": "Fatima",
            "community_profile": "matrimonial_muslim",
        }
        prompt = bootstrap_main._build_system_prompt(profile, [], [])
        self.assertIn("Muslim Matrimonial", prompt)
        self.assertIn("nikah", prompt.lower())


class PostTurnWikiTests(unittest.TestCase):
    """Verify post-turn wiki extraction and preference updates."""

    def test_post_turn_extracts_and_saves_wiki_from_conversation(self):
        """post_turn should call Gemini, parse JSON, and update the user's wiki in the DB."""
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()
                bootstrap_main.app.state.pool = pool

                uid = "priya-wiki-test"
                async with pool.acquire() as conn:
                    await conn.execute(
                        "INSERT INTO users (id, display_name) VALUES ($1, $2)", uid, "Priya"
                    )

                wiki_payload = {
                    "wiki_updates": {
                        "about_me": "- She is 28 years old\n- She is a software engineer",
                        "context": "- She lives in Toronto\n- Originally from Chennai",
                        "preferences": "- She wants to marry\n- Prefers South Indian partner",
                        "matching": ""
                    },
                    "extracted_answers": [{"id": "diet", "value": "vegetarian", "confidence": "high"}],
                    "answered_question_keys": ["diet"],
                    "public_summary": "Priya is a 28-year-old engineer in Toronto."
                }

                class MockModel:
                    def __init__(self, *a, **kw): pass
                    async def generate_content_async(self, *a, **kw):
                        return types.SimpleNamespace(text=json.dumps(wiki_payload))

                original = bootstrap_main.genai.GenerativeModel
                bootstrap_main.genai.GenerativeModel = MockModel
                try:
                    messages = [
                        {"role": "user", "text": "I'm Priya, 28, software engineer in Toronto."},
                        {"role": "model", "text": "Nice to meet you! What brought you here?"},
                        {"role": "user", "text": "Tamil Brahmin. Vegetarian. Want to marry someone South Indian."},
                    ]
                    req = bootstrap_main.PostTurnRequest(session_id="s1", messages=messages)
                    result = await bootstrap_main.post_turn(request=None, body=req, uid=uid)
                    self.assertEqual(result["updated"], True)
                finally:
                    bootstrap_main.genai.GenerativeModel = original

                raw = sqlite3.connect(db_path)
                try:
                    row = raw.execute(
                        "SELECT wiki_about_me, wiki_context, wiki_preferences FROM users WHERE id = ?",
                        (uid,)
                    ).fetchone()
                    self.assertIsNotNone(row)
                    self.assertIn("28 years old", row[0])
                    self.assertIn("Toronto", row[1])
                    self.assertIn("South Indian", row[2])
                finally:
                    raw.close()

        asyncio.run(_run())

    def test_post_turn_updates_softened_preference(self):
        """When user softens a preference, post-turn must update the wiki bullet, not keep old version."""
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()
                bootstrap_main.app.state.pool = pool

                uid = "priya-soften-test"
                old_prefs = "- She wants someone South Indian, ideally\n- She wants someone career-stable"
                async with pool.acquire() as conn:
                    await conn.execute(
                        "INSERT INTO users (id, display_name, wiki_preferences) VALUES ($1, $2, $3)",
                        uid, "Priya", old_prefs
                    )

                # Gemini correctly processes the softening and returns updated preferences
                updated_prefs = (
                    "- She prefers South Indian but is open to others with strong values\n"
                    "- She wants someone career-stable"
                )
                wiki_payload = {
                    "wiki_updates": {
                        "about_me": "",
                        "context": "",
                        "preferences": updated_prefs,
                        "matching": ""
                    },
                    "extracted_answers": [],
                    "answered_question_keys": [],
                    "public_summary": ""
                }

                class MockModel:
                    def __init__(self, *a, **kw): pass
                    async def generate_content_async(self, *a, **kw):
                        return types.SimpleNamespace(text=json.dumps(wiki_payload))

                original = bootstrap_main.genai.GenerativeModel
                bootstrap_main.genai.GenerativeModel = MockModel
                try:
                    messages = [
                        {"role": "user", "text": "I'm open to outside Tamil now — values matter more than background."},
                        {"role": "model", "text": "That's a meaningful shift. What values matter most?"},
                        {"role": "user", "text": "South Indian still preferred but it's not a hard rule."},
                    ]
                    req = bootstrap_main.PostTurnRequest(session_id="s2", messages=messages)
                    await bootstrap_main.post_turn(request=None, body=req, uid=uid)
                finally:
                    bootstrap_main.genai.GenerativeModel = original

                raw = sqlite3.connect(db_path)
                try:
                    row = raw.execute("SELECT wiki_preferences FROM users WHERE id = ?", (uid,)).fetchone()
                    prefs = row[0]
                    self.assertIn("open to others with strong values", prefs,
                        "Softened preference must appear in updated wiki")
                    self.assertNotIn("ideally\n", prefs,
                        "Old strict preference 'ideally' must be replaced by the softer version")
                    self.assertIn("career-stable", prefs,
                        "Unrelated preference must be preserved")
                finally:
                    raw.close()

        asyncio.run(_run())

    def test_post_turn_preserves_existing_wiki_when_nothing_new(self):
        """If Gemini returns empty wiki updates, existing wiki must be preserved."""
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()
                bootstrap_main.app.state.pool = pool

                uid = "priya-preserve-test"
                existing_about = "- She is 28 years old\n- She is a software engineer"
                async with pool.acquire() as conn:
                    await conn.execute(
                        "INSERT INTO users (id, display_name, wiki_about_me) VALUES ($1, $2, $3)",
                        uid, "Priya", existing_about
                    )

                class MockModel:
                    def __init__(self, *a, **kw): pass
                    async def generate_content_async(self, *a, **kw):
                        return types.SimpleNamespace(text=json.dumps({
                            "wiki_updates": {"about_me": "", "context": "", "preferences": "", "matching": ""},
                            "extracted_answers": [], "answered_question_keys": [], "public_summary": ""
                        }))

                original = bootstrap_main.genai.GenerativeModel
                bootstrap_main.genai.GenerativeModel = MockModel
                try:
                    req = bootstrap_main.PostTurnRequest(
                        session_id="s3",
                        messages=[{"role": "user", "text": "hey"}, {"role": "model", "text": "hi!"}]
                    )
                    await bootstrap_main.post_turn(request=None, body=req, uid=uid)
                finally:
                    bootstrap_main.genai.GenerativeModel = original

                raw = sqlite3.connect(db_path)
                try:
                    row = raw.execute("SELECT wiki_about_me FROM users WHERE id = ?", (uid,)).fetchone()
                    self.assertEqual(row[0], existing_about,
                        "Existing wiki must be preserved when no new info was extracted")
                finally:
                    raw.close()

        asyncio.run(_run())


class MatchingPipelineTests(unittest.TestCase):
    """Verify the full matching pipeline: heuristic filter → scoring → DB write → /matches."""

    async def _setup_two_users(self, pool, uid_a, uid_b):
        """Create two compatible users in the DB."""
        for uid, name, gender, age, interested_in in [
            (uid_a, "Priya", "Female", 28, "Male"),
            (uid_b, "Arjun", "Male", 30, "Female"),
        ]:
            body = bootstrap_main.ProfileUpdateBody(
                display_name=name,
                gender=gender,
                age=age,
                community_profile="arranged_india",
                onboarding_complete=True,
                matching_prefs={"interested_in": interested_in},
                wiki_preferences=f"- Wants a {interested_in.lower()} partner, 25-35",
            )
            await bootstrap_main.update_profile(body, uid=uid)

    def test_matching_creates_match_when_gemini_returns_high_score(self):
        """run_matching must create a match record when _score_pair returns score >= 0.4."""
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()
                bootstrap_main.app.state.pool = pool

                uid_a = "priya-match-uid"
                uid_b = "arjun-match-uid"
                await self._setup_two_users(pool, uid_a, uid_b)

                # Use score 0.55: above 0.4 match threshold, below 0.65 vibe threshold
                # → match is created without blending, DB score = exactly 0.55
                original = bootstrap_main._score_pair
                async def mock_score(model, me, other):
                    return {
                        "score": 0.55,
                        "rationale": "Both value family and career stability",
                        "summary_a": "Priya is looking for a stable family-oriented partner",
                        "summary_b": "Arjun values family and wants someone like-minded",
                    }
                bootstrap_main._score_pair = mock_score

                try:
                    result = await bootstrap_main.run_matching(request=None, uid=uid_a)
                finally:
                    bootstrap_main._score_pair = original

                self.assertGreater(result["matches_created"], 0,
                    f"Expected ≥1 match created, got: {result}")
                self.assertEqual(result["candidates_evaluated"], 1,
                    "Should evaluate exactly 1 candidate (Arjun)")

                # Verify match exists in DB with correct score
                raw = sqlite3.connect(db_path)
                try:
                    row = raw.execute("SELECT user_a, user_b, score, rationale FROM matches LIMIT 1").fetchone()
                    self.assertIsNotNone(row, "Match must exist in DB after run_matching")
                    users = {row[0], row[1]}
                    self.assertEqual(users, {uid_a, uid_b}, "Match must be between the two test users")
                    self.assertAlmostEqual(float(row[2]), 0.55, places=2)
                    self.assertIn("family", row[3])
                finally:
                    raw.close()

        asyncio.run(_run())

    def test_matching_no_match_when_score_below_threshold(self):
        """run_matching must NOT create a match when score < 0.4."""
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()
                bootstrap_main.app.state.pool = pool

                uid_a = "user-low-score-a"
                uid_b = "user-low-score-b"
                await self._setup_two_users(pool, uid_a, uid_b)

                original = bootstrap_main._score_pair
                async def mock_low_score(model, me, other):
                    return {"score": 0.25, "rationale": "Poor compatibility", "summary_a": "", "summary_b": ""}
                bootstrap_main._score_pair = mock_low_score

                try:
                    result = await bootstrap_main.run_matching(request=None, uid=uid_a)
                finally:
                    bootstrap_main._score_pair = original

                self.assertEqual(result["matches_created"], 0,
                    "Score below threshold must not create a match")

        asyncio.run(_run())

    def test_get_matches_returns_created_match(self):
        """/matches endpoint must return matches that were written by run_matching."""
        async def _run():
            with tempfile.TemporaryDirectory() as tmpdir:
                db_path = Path(tmpdir) / "test.db"
                pool = mock_db.MockPool(db_path=str(db_path))
                await pool.init_db()
                bootstrap_main.app.state.pool = pool

                uid_a = "priya-get-uid"
                uid_b = "arjun-get-uid"
                await self._setup_two_users(pool, uid_a, uid_b)

                # Score 0.58: above threshold (0.4), below vibe threshold (0.65) → exact score in DB
                original = bootstrap_main._score_pair
                async def mock_score(model, me, other):
                    return {"score": 0.58, "rationale": "Good match", "summary_a": "S-A", "summary_b": "S-B"}
                bootstrap_main._score_pair = mock_score

                try:
                    await bootstrap_main.run_matching(request=None, uid=uid_a)
                finally:
                    bootstrap_main._score_pair = original

                matches = await bootstrap_main.get_matches(uid=uid_a)
                self.assertIsInstance(matches, list)
                self.assertGreater(len(matches), 0, "get_matches must return the created match")
                m = matches[0]
                self.assertIn("other_display_name", m)
                self.assertEqual(m["other_display_name"], "Arjun")
                self.assertAlmostEqual(float(m["score"]), 0.58, places=2)

        asyncio.run(_run())

    def test_heuristic_filter_blocks_same_gender_interest(self):
        """Heuristic must block pairs where gender interest doesn't match."""
        me = {"gender": "Female", "age": 28, "matching_prefs": {"interested_in": "Male"}}
        other_female = {"gender": "Female", "age": 27, "matching_prefs": {"interested_in": "Female"}}
        other_male = {"gender": "Male", "age": 30, "matching_prefs": {"interested_in": "Female"}}

        self.assertFalse(bootstrap_main._is_heuristic_match(me, other_female),
            "Female interested in Male must not match with Female interested in Female")
        self.assertTrue(bootstrap_main._is_heuristic_match(me, other_male),
            "Female interested in Male must match with Male interested in Female")

    def test_heuristic_filter_blocks_age_out_of_range(self):
        """Heuristic must block candidates outside the user's stated age preference."""
        me = {"gender": "Female", "age": 28, "matching_prefs": {"interested_in": "Male", "age_min": 27, "age_max": 35}}
        too_young = {"gender": "Male", "age": 24, "matching_prefs": {"interested_in": "Female"}}
        too_old   = {"gender": "Male", "age": 40, "matching_prefs": {"interested_in": "Female"}}
        just_right = {"gender": "Male", "age": 31, "matching_prefs": {"interested_in": "Female"}}

        self.assertFalse(bootstrap_main._is_heuristic_match(me, too_young))
        self.assertFalse(bootstrap_main._is_heuristic_match(me, too_old))
        self.assertTrue(bootstrap_main._is_heuristic_match(me, just_right))


if __name__ == "__main__":
    unittest.main()
