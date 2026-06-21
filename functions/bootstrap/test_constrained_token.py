import os
import json
import asyncio
import websockets
import urllib.parse
from datetime import datetime, timezone, timedelta
from google import genai

async def test_constrained():
    key = os.environ.get("GOOGLE_API_KEY", "")
    c = genai.Client(api_key=key, http_options={"api_version": "v1alpha"})
    now = datetime.now(timezone.utc)
    
    setup_backend = {
        "model": "models/gemini-3.1-flash-live-preview",
        "system_instruction": {"parts": [{"text": "You are Ayma, a warm personal AI matchmaker."}]},
        "generation_config": {
            "response_modalities": ["AUDIO"],
            "speech_config": {
                "voice_config": {
                    "prebuilt_voice_config": {"voice_name": "Charon"}
                }
            },
        },
        "input_audio_transcription": {},
        "tools": [{
            "functionDeclarations": [{
                "name": "add_followup_question",
                "description": "Note a question to come back to.",
                "parameters": {
                    "type": "OBJECT",
                    "properties": {
                        "question": {"type": "STRING"}
                    },
                    "required": ["question"],
                },
            }]
        }],
    }

    print("Creating token...")
    try:
        t = c.auth_tokens.create(config={
            "uses": 1,
            "expire_time": (now + timedelta(minutes=10)).isoformat(),
            "live_connect_constraints": {
                "model": setup_backend["model"],
                "config": {
                    "system_instruction": setup_backend["system_instruction"],
                    "generation_config": setup_backend["generation_config"],
                    "tools": setup_backend["tools"],
                    "input_audio_transcription": setup_backend["input_audio_transcription"]
                }
            }
        })
        print("Token created successfully:", t.name)
    except Exception as e:
        print("Token creation failed:", e)
        return

    wsUrl = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained"
    token = t.name
    
    encoded_token = urllib.parse.quote(token, safe='')
    uri = f"{wsUrl}?access_token={encoded_token}"
    
    # Normalize setup key format to camelCase like Dart
    def camel_case(s):
        import re
        return re.sub(r'_([a-z])', lambda m: m.group(1).toUpperCase(), s) if isinstance(s, str) else s
        
    def normalize(val):
        if isinstance(val, dict):
            out = {}
            for k, v in val.items():
                if k == "system_instruction":
                    out["systemInstruction"] = normalize(v)
                elif k == "generation_config":
                    out["generationConfig"] = normalize(v)
                elif k == "response_modalities":
                    out["responseModalities"] = normalize(v)
                elif k == "speech_config":
                    out["speechConfig"] = normalize(v)
                elif k == "voice_config":
                    out["voiceConfig"] = normalize(v)
                elif k == "prebuilt_voice_config":
                    out["prebuiltVoiceConfig"] = normalize(v)
                elif k == "voice_name":
                    out["voiceName"] = normalize(v)
                elif k == "input_audio_transcription":
                    out["inputAudioTranscription"] = normalize(v)
                elif k == "function_declarations":
                    out["functionDeclarations"] = normalize(v)
                else:
                    out[k] = normalize(v)
            return out
        if isinstance(val, list):
            return [normalize(v) for v in val]
        return val
        
    setup_client = {"setup": normalize(setup_backend)}
    print("Setup client payload:")
    print(json.dumps(setup_client, indent=2))
    
    try:
        async with websockets.connect(uri) as ws:
            print("Connected to WebSocket!")
            await ws.send(json.dumps(setup_client))
            print("Sent setup payload.")
            
            while True:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=5.0)
                    print("Received message:", msg)
                except asyncio.TimeoutError:
                    print("No messages for 5s, closing.")
                    break
                except websockets.exceptions.ConnectionClosed as e:
                    print(f"Connection closed by server: {e.code} - {e.reason}")
                    break
    except Exception as e:
        print("WebSocket Error:", e)

if __name__ == "__main__":
    asyncio.run(test_constrained())
