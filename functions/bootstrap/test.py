import os
import asyncio
from datetime import datetime, timezone, timedelta
from google import genai
import google.genai.errors

async def test_ws():
    # Use the same API key logic as main.py
    import firebase_admin
    from firebase_admin import credentials, firestore
    try:
        firebase_admin.get_app()
    except ValueError:
        firebase_admin.initialize_app()
    db = firestore.client()
    doc = db.collection('platform_keys').document('primary').get()
    key = doc.to_dict().get("gemini_api_key")
    
    c = genai.Client(api_key=key, http_options={"api_version": "v1alpha"})
    now = datetime.now(timezone.utc)
    
    setup_backend = {
        "model": "models/gemini-3.1-flash-live-preview",
        "system_instruction": {"parts": [{"text": "Hello"}]},
        "generation_config": {
            "response_modalities": ["AUDIO"],
        }
    }

    print("Testing without input_audio_transcription...")
    try:
        t = c.auth_tokens.create(config={
            "uses": 1,
            "expire_time": (now + timedelta(minutes=10)).isoformat(),
            "live_connect_constraints": {
                "model": setup_backend["model"],
                "config": {
                    "system_instruction": setup_backend["system_instruction"],
                    "generation_config": setup_backend["generation_config"],
                }
            }
        })
        print("Success without input_audio_transcription!", t.name)
    except Exception as e:
        print("Error without:", e)

    print("Testing with input_audio_transcription...")
    try:
        t = c.auth_tokens.create(config={
            "uses": 1,
            "expire_time": (now + timedelta(minutes=10)).isoformat(),
            "live_connect_constraints": {
                "model": setup_backend["model"],
                "config": {
                    "system_instruction": setup_backend["system_instruction"],
                    "generation_config": setup_backend["generation_config"],
                    "input_audio_transcription": {}
                }
            }
        })
        print("Success with input_audio_transcription!", t.name)
    except Exception as e:
        print("Error with:", e)

if __name__ == "__main__":
    asyncio.run(test_ws())
