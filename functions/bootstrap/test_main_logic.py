import asyncio
import importlib.util
import json
import os
import sys
import types
import unittest
from pathlib import Path
import re


def _install_test_stubs():
    os.environ.setdefault("GOOGLE_API_KEY", "test-key")
    os.environ.setdefault("ADMIN_PASSWORD", "test-admin-pass")

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
    def test_require_admin_access_accepts_password(self):
        allowed = bootstrap_main._require_admin_access("test-admin-pass")
        self.assertTrue(allowed)

    def test_require_admin_access_rejects_wrong_password(self):
        with self.assertRaises(bootstrap_main.HTTPException) as ctx:
            bootstrap_main._require_admin_access("wrong-pass")
        self.assertEqual(ctx.exception.status_code, 401)

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


class HeuristicMatchingTests(unittest.TestCase):
    def test_heuristic_filter_blocks_same_gender_interest(self):
        me = {"gender": "Female", "age": 28, "matching_prefs": {"interested_in": "Male"}}
        other_female = {"gender": "Female", "age": 27, "matching_prefs": {"interested_in": "Female"}}
        other_male = {"gender": "Male", "age": 30, "matching_prefs": {"interested_in": "Female"}}
        self.assertFalse(bootstrap_main._is_heuristic_match(me, other_female))
        self.assertTrue(bootstrap_main._is_heuristic_match(me, other_male))

    def test_heuristic_filter_blocks_age_out_of_range(self):
        me = {"gender": "Female", "age": 28, "matching_prefs": {"interested_in": "Male", "age_min": 27, "age_max": 35}}
        too_young = {"gender": "Male", "age": 24, "matching_prefs": {"interested_in": "Female"}}
        too_old = {"gender": "Male", "age": 40, "matching_prefs": {"interested_in": "Female"}}
        just_right = {"gender": "Male", "age": 31, "matching_prefs": {"interested_in": "Female"}}
        self.assertFalse(bootstrap_main._is_heuristic_match(me, too_young))
        self.assertFalse(bootstrap_main._is_heuristic_match(me, too_old))
        self.assertTrue(bootstrap_main._is_heuristic_match(me, just_right))


if __name__ == "__main__":
    unittest.main()
