import asyncio
import json
import unittest
from unittest.mock import AsyncMock, MagicMock, patch
from fastapi.testclient import TestClient

# Import app and auth dependency override
from functions.bootstrap.main import app, verify_token

# Override token verification dependency for testing
app.dependency_overrides[verify_token] = lambda: "test_user_uid"

class TestMatchingEndpoints(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        
        # Mock connection pool and connection
        self.mock_pool = MagicMock()
        self.mock_conn = AsyncMock()
        
        # Async context manager mock for pool.acquire()
        self.mock_pool.acquire.return_value.__aenter__.return_value = self.mock_conn
        app.state.pool = self.mock_pool

    @patch("google.generativeai.GenerativeModel")
    @patch("google.generativeai.embed_content")
    def test_run_matching_success(self, mock_embed, mock_gen_model_class):
        # Mock embedding return value
        mock_embed.return_value = {"embedding": [0.05] * 1536}
        
        # Mock Gemini Model responses
        mock_model = MagicMock()
        mock_model.generate_content_async = AsyncMock()
        mock_gen_model_class.return_value = mock_model
        
        # Mock compatibility scoring response
        mock_compat_resp = MagicMock()
        mock_compat_resp.text = json.dumps({
            "score": 0.88,
            "rationale": "Perfect values alignment and lifestyle compat.",
            "summary_a": "Candidate is great for you.",
            "summary_b": "You are great for candidate."
        })
        
        # Mock vibe check dialogue simulation response
        mock_sim_resp = MagicMock()
        mock_sim_resp.text = "A: Hey, how is it going?\nB: Pretty good! Just coding.\nA: Me too, python is great.\nB: Absolutely, asyncpg works well.\nA: Let's run unit tests!"
        
        # Mock vibe check scoring response
        mock_vibe_score_resp = MagicMock()
        mock_vibe_score_resp.text = json.dumps({
            "synergyScore": 95,
            "synergySummary": "Exceptional conversational flow and shared interest."
        })
        
        # AsyncMock returns the MagicMock when awaited
        mock_model.generate_content_async.side_effect = [
            mock_compat_resp,
            mock_sim_resp,
            mock_vibe_score_resp
        ]
        
        # Mock database rows for 'me' and 'candidate'
        me_row = {
            "id": "test_user_uid",
            "display_name": "Me",
            "age": 28,
            "gender": "male",
            "matching_prefs": '{"interested_in": "women", "age_min": 20, "age_max": 35}',
            "onboarding_complete": True,
            "matching_paused": False,
            "matching_embedding": None,
            "wiki_preferences": "Looking for female coder",
            "wiki_matching": "Prefers python developer",
        }
        
        candidate_row = {
            "id": "candidate_uid_1",
            "display_name": "Candidate 1",
            "age": 25,
            "gender": "female",
            "matching_prefs": '{"interested_in": "men", "age_min": 25, "age_max": 35}',
            "onboarding_complete": True,
            "matching_paused": False,
            "matching_embedding": "[0.01]*1536",
            "wiki_about_me": "Fascinated by postgres, writes dart code",
            "wiki_preferences": "Looking for python developer",
            "wiki_matching": "Prefers age 25-35",
        }
        
        # Set database mock return values
        self.mock_conn.fetchrow.side_effect = [
            me_row,          # 1. Fetching 'me' in /run-matching
            me_row,          # 2. Fetching User A (me) in _run_vibe_check
            candidate_row,   # 3. Fetching User B (candidate) in _run_vibe_check
        ]
        
        self.mock_conn.fetch.side_effect = [
            [candidate_row],  # candidates fetched by query
        ]
        
        self.mock_conn.fetchval.return_value = 42  # mock returning serial match_id = 42
        
        response = self.client.post("/run-matching")
        self.assertEqual(response.status_code, 200)
        res_data = response.json()
        self.assertEqual(res_data["matches_created"], 1)
        self.assertEqual(res_data["candidates_evaluated"], 1)
        
        # Verify execution calls
        self.mock_conn.fetchval.assert_called_once()
        self.mock_conn.execute.assert_called()

    @patch("google.generativeai.GenerativeModel")
    def test_vibe_check_success(self, mock_gen_model_class):
        # Mock Gemini
        mock_model = MagicMock()
        mock_model.generate_content_async = AsyncMock()
        mock_gen_model_class.return_value = mock_model
        
        mock_sim_resp = MagicMock()
        mock_sim_resp.text = "A: Hey!\nB: Hello!\nA: Nice weather.\nB: Yes it is.\nA: Talk to you soon!"
        
        mock_vibe_score_resp = MagicMock()
        mock_vibe_score_resp.text = json.dumps({
            "synergyScore": 85,
            "synergySummary": "Good casual rapport."
        })
        mock_model.generate_content_async.side_effect = [mock_sim_resp, mock_vibe_score_resp]
        
        # Mock database calls
        match_row = {
            "id": 42,
            "user_a": "test_user_uid",
            "user_b": "candidate_uid_1",
            "score": 0.80,
            "status": "pending",
        }
        profile_a_row = {
            "id": "test_user_uid",
            "display_name": "Me",
            "wiki_about_me": "Coder",
        }
        profile_b_row = {
            "id": "candidate_uid_1",
            "display_name": "Candidate 1",
            "wiki_about_me": "Designer",
        }
        
        self.mock_conn.fetchrow.side_effect = [
            match_row,       # for get match status
            profile_a_row,   # for user A in vibe check simulation
            profile_b_row,   # for user B in vibe check simulation
        ]
        
        response = self.client.post("/vibe-check", json={"match_id": 42})
        self.assertEqual(response.status_code, 200)
        res_data = response.json()
        self.assertEqual(res_data["synergy_score"], 85)
        self.assertEqual(res_data["synergy_summary"], "Good casual rapport.")
        
        # Verify simulations insert turns
        self.mock_conn.execute.assert_called()

    def test_get_match_simulation_success(self):
        # Mock database rows
        match_row = {
            "user_a": "test_user_uid",
            "user_b": "candidate_uid_1",
            "show_simulation_transcript": True,
        }
        simulation_turns = [
            {
                "sender_uid": "test_user_uid",
                "turn_index": 0,
                "message_text": "Hey there!",
                "created_at": MagicMock(isoformat=lambda: "2026-06-19T00:00:00Z"),
            },
            {
                "sender_uid": "candidate_uid_1",
                "turn_index": 1,
                "message_text": "Hi!",
                "created_at": MagicMock(isoformat=lambda: "2026-06-19T00:00:01Z"),
            }
        ]
        
        self.mock_conn.fetchrow.return_value = match_row
        self.mock_conn.fetch.return_value = simulation_turns
        
        response = self.client.get("/matches/42/simulation")
        self.assertEqual(response.status_code, 200)
        res_data = response.json()
        self.assertEqual(len(res_data), 2)
        self.assertEqual(res_data[0]["message_text"], "Hey there!")
        self.assertEqual(res_data[1]["message_text"], "Hi!")

    def test_get_match_simulation_unauthorized(self):
        # Current user is not in user_a or user_b
        match_row = {
            "user_a": "someone_else_1",
            "user_b": "someone_else_2",
            "show_simulation_transcript": True,
        }
        self.mock_conn.fetchrow.return_value = match_row
        
        response = self.client.get("/matches/42/simulation")
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()["detail"], "Not authorized to view this match simulation")

    def test_toggle_match_simulation_success(self):
        match_row = {
            "user_a": "test_user_uid",
            "user_b": "candidate_uid_1",
        }
        self.mock_conn.fetchrow.return_value = match_row
        
        response = self.client.post("/matches/42/toggle-simulation", json={"show_simulation_transcript": False})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"success": True})
        
        # Verify UPDATE matches query execution
        self.mock_conn.execute.assert_called_once()

if __name__ == "__main__":
    unittest.main()
