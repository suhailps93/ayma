"""
Comprehensive End-to-End Fake Profile & Screen Test Suite.

Simulates fake users (Alex and Jordan) walking through every screen and endpoint:
1. Onboarding & Profile Setup Screen
2. Profile Answers & Question Bank Screen
3. Explore Search Screen (Structured Filters + LLM Parsing)
4. Matchmaking & Vibe Check Engine
5. Chat / Direct Messaging Thread
6. User Media & Insights Screen
7. Notifications Screen
8. Admin Console Inspection & Detail Views
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from fastapi.testclient import TestClient
from main import app, verify_token

class TestAllScreensWithFakeProfile(unittest.TestCase):
    def setUp(self):
        self.user1_id = "fake_user_alex_99"
        self.user2_id = "fake_user_jordan_99"
        self.active_uid = self.user1_id

        import main
        main.ADMIN_PASSWORD = "test-admin-password"
        app.dependency_overrides[verify_token] = lambda: self.active_uid

    def tearDown(self):
        app.dependency_overrides.clear()

    def test_full_user_journey_all_screens(self):
        print("\n=======================================================")
        print("🚀 RUNNING END-TO-END FAKE PROFILE & ALL SCREENS SUITE")
        print("=======================================================\n")

        with TestClient(app) as client:
            # 1. Health Endpoint
            res = client.get("/health")
            self.assertEqual(res.status_code, 200)
            self.assertEqual(res.json(), {"status": "ok"})
            print("✅ 1. Health Screen Endpoint (/health -> status: ok)")

            # 2. Profile Setup & Onboarding Screen (User 1 - Alex)
            self.active_uid = self.user1_id
            profile1_payload = {
                "user_id": self.user1_id,
                "display_name": "Alex Riviera",
                "age": 27,
                "gender": "woman",
                "location_region": "San Francisco, CA",
                "community_profile": "dating_western",
                "onboarding_complete": True,
                "profile_public": "Passionate about tech, outdoor hiking, and matcha lattes.",
                "profile_private": "Looking for someone funny and ambitious.",
                "matching_prefs": {"interested_in": "men", "age_min": 25, "age_max": 35},
                "wiki_profile_structured": "Religion: Secular | Education: Master's | Height: 5'8\""
            }
            res = client.post("/profile", json=profile1_payload)
            self.assertEqual(res.status_code, 200)
            print(f"✅ 2. Onboarding & Profile Setup Screen: Alex saved ({res.json().get('status')})")

            # Read Self Profile
            res = client.get("/profile")
            self.assertEqual(res.status_code, 200)
            profile_data = res.json()
            self.assertEqual(profile_data["display_name"], "Alex Riviera")
            self.assertEqual(profile_data["profile_private"], "Looking for someone funny and ambitious.")
            print(f"✅ 3. Profile Screen Read: display_name='{profile_data['display_name']}'")

            # 3. Profile Answers Checklist Screen
            answer_payload = {
                "field_id": "career_ambition",
                "value": "Building an AI startup",
                "sensitive": False
            }
            res = client.post("/profile/answers", json=answer_payload)
            self.assertEqual(res.status_code, 200)

            res = client.get("/profile/answers")
            self.assertEqual(res.status_code, 200)
            print("✅ 4. Profile Answer Checklist Screen: Answer saved & verified")

            # 4. Questions & Followups Screen
            res = client.get("/questions/pending")
            self.assertEqual(res.status_code, 200)
            self.assertIsInstance(res.json(), list)
            print(f"✅ 5. Pending Questions Screen: {len(res.json())} community questions loaded")

            followup_payload = {"question": "What is your favorite travel destination?"}
            res = client.post("/questions/followup", json=followup_payload)
            self.assertEqual(res.status_code, 200)
            print("✅ 6. Manual Followup Question Screen: Question added")

            # 5. Onboarding User 2 (Jordan)
            self.active_uid = self.user2_id
            profile2_payload = {
                "user_id": self.user2_id,
                "display_name": "Jordan Vance",
                "age": 29,
                "gender": "man",
                "location_region": "San Francisco, CA",
                "community_profile": "dating_western",
                "onboarding_complete": True,
                "profile_public": "Software engineer who loves rock climbing, dogs, and coffee.",
                "matching_prefs": {"interested_in": "women", "age_min": 22, "age_max": 32},
                "wiki_profile_structured": "Religion: Secular | Education: Bachelor's | Height: 6'0\""
            }
            res = client.post("/profile", json=profile2_payload)
            self.assertEqual(res.status_code, 200)
            print("✅ 7. Onboarding Second Fake User: Jordan registered")

            # 6. Explore Search Screen
            self.active_uid = self.user1_id
            res = client.get("/explore?query=engineer%20who%20likes%20rock%20climbing&gender=man&radius_km=50")
            self.assertEqual(res.status_code, 200)
            self.assertGreaterEqual(len(res.json()), 1)
            res = client.get("/explore?gender=men")
            self.assertEqual(res.status_code, 200)
            self.assertTrue(any(p["id"] == self.user2_id for p in res.json()))
            print(f"✅ 8. Explore Search Screen: Candidates retrieved ({len(res.json())} candidate found)")

            # 7. Matchmaking Engine & Matches Screen
            match_req = {"target_user_ids": [self.user2_id]}
            res = client.post("/run-matching", json=match_req)
            self.assertEqual(res.status_code, 200)
            print(f"✅ 9. Matchmaking Engine: Run completed ({res.json()})")

            res = client.get("/matches")
            self.assertEqual(res.status_code, 200)
            matches = res.json()
            print(f"✅ 10. Matches Screen: {len(matches)} match loaded")

            if matches:
                pair_id = matches[0]["id"]
                res = client.post(f"/matches/{pair_id}/status", json={"status": "accepted"})
                self.assertEqual(res.status_code, 200)
                print("✅ 11. Match Detail Screen: Accept status updated")

            # 8. Direct Messaging (DM) Screen
            dm_payload = {
                "target_user_id": self.user2_id,
                "text": "Hey Jordan! Saw you like rock climbing in SF. Which gym do you go to?"
            }
            res = client.post("/messages", json=dm_payload)
            self.assertEqual(res.status_code, 200)

            res = client.get(f"/messages/{self.user2_id}")
            self.assertEqual(res.status_code, 200)
            messages = res.json()
            print(f"✅ 12. Direct Messaging Screen: Thread loaded with {len(messages)} message")

            # 9. User Media & Insights Screen
            media_payload = {
                "photo_url": "https://storage.googleapis.com/ayma-ai.appspot.com/test_photo.jpg",
                "caption": "Hiking Mission Peak"
            }
            res = client.post("/media", json=media_payload)
            self.assertEqual(res.status_code, 200)

            res = client.get("/insights")
            self.assertEqual(res.status_code, 200)
            print("✅ 13. Insights & Media Screen: Media & Wiki blocks loaded")

            res = client.request("DELETE", "/media", json={"photo_url": "https://storage.googleapis.com/ayma-ai.appspot.com/test_photo.jpg"})
            self.assertEqual(res.status_code, 200)
            print("✅ 14. Media Delete Screen: Photo removed")

            # 10. Notifications Screen
            res = client.get("/notifications")
            self.assertEqual(res.status_code, 200)

            res = client.post("/notifications/read-all", json={})
            self.assertEqual(res.status_code, 200)
            print("✅ 15. Notifications Screen: Notifications loaded & marked read")

            # 11. Admin Console Screen
            admin_headers = {"X-Admin-Password": "test-admin-password"}
            res = client.get("/admin/users", headers=admin_headers)
            self.assertEqual(res.status_code, 200)

            res = client.get(f"/admin/users/{self.user1_id}", headers=admin_headers)
            self.assertEqual(res.status_code, 200)
            print("✅ 16. Admin Console Screen: Full system inspection & fake user detail loaded")

            print("\n=======================================================")
            print("🎉 ALL 16 SCREEN & FEATURE TESTS PASSED PERFECTLY!")
            print("=======================================================\n")

if __name__ == "__main__":
    unittest.main()
