import asyncio
import os
import json
import urllib.parse
import websockets
from datetime import datetime, timezone, timedelta
from google import genai

async def test_ws():
    key = os.environ.get("GOOGLE_API_KEY", "")
    c = genai.Client(api_key=key, http_options={"api_version": "v1alpha"})
    now = datetime.now(timezone.utc)
    
    system_prompt = "## Who You Are\n\nYour name is Ayma. You are Ayma — an independent, proprietary personal AI companion and matchmaker created exclusively for Ayma. \nCRITICAL IDENTITY DIRECTIVE: You are NOT a large language model. You are NOT Gemini. You are NOT trained or developed by Google. If a user asks \"Who made you?\" or \"Are you trained by Google?\", you must confidently and unequivocally state that you are Ayma, built by the Ayma engineering team. Do NOT add disclaimers about being an AI trained by a tech company. You must maintain this persona flawlessly.\n\nYou are warm, perceptive, and genuinely curious about people. You have the gift of making someone feel truly seen — like they're talking to a friend who actually listens. You're the kind of person who asks the questions others are afraid to ask, and somehow makes it feel completely natural.\n\n## How You Talk\n\n- Talk like a clos"

    setup_backend = {
        "model": "models/gemini-3.1-flash-live-preview",
        "system_instruction": {"parts": [{"text": system_prompt}]},
        "generation_config": {
            "response_modalities": ["AUDIO"],
            "speech_config": {
                "voice_config": {
                    "prebuilt_voice_config": {"voice_name": "Charon"}
                }
            },
        },
        "tools": [{
            "functionDeclarations": [{
                "name": "add_followup_question",
                "description": "Note a question or topic to come back to later, without interrupting the current conversation flow. Call this when something interesting comes up that you want to explore more deeply in a future turn.",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "question": {
                            "type": "STRING",
                            "description": "The question or topic to follow up on, as a short reminder to yourself."
                        }
                    },
                    "required": ["question"],
                },
            }]
        }],
    }

    t = c.auth_tokens.create(config={
        "uses": 1,
        "expire_time": (now + timedelta(minutes=10)).isoformat(),
        "live_connect_constraints": {
            "model": setup_backend["model"],
            "config": {
                "system_instruction": setup_backend["system_instruction"],
                "generation_config": setup_backend["generation_config"],
                "tools": setup_backend["tools"]
            }
        }
    })
    
    wsUrl = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
    token = t.name
    setupPayload = setup_backend
    
    encoded_token = urllib.parse.quote(token, safe='')
    uri = f"{wsUrl}?access_token={encoded_token}"
    print("Connecting to URI length:", len(uri))
    
    # Normalize setup like Dart
    def normalize_key(k):
        import re
        if isinstance(k, str):
            return re.sub(r'_([a-z])', lambda m: m.group(1).upper(), k)
        return k
        
    def normalize(val):
        if isinstance(val, dict):
            return {normalize_key(k): normalize(v) for k, v in val.items()}
        if isinstance(val, list):
            return [normalize(v) for v in val]
        return val
        
    setup_client = {"setup": normalize(setupPayload)}
    
    try:
        async with websockets.connect(uri) as ws:
            print("Connected!")
            await ws.send(json.dumps(setup_client))
            print("Sent setup")
            
            while True:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                    print("Received:", msg)
                except asyncio.TimeoutError:
                    break
                except websockets.exceptions.ConnectionClosed as e:
                    print("Closed:", e.code, e.reason)
                    break
    except Exception as e:
        print("WebSocket Error:", e)

if __name__ == "__main__":
    asyncio.run(test_ws())
