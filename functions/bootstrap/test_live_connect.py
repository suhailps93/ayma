import os
import json
from datetime import datetime, timezone, timedelta
from google import genai
from google.genai.types import CreateAuthTokenConfig, LiveConnectConstraints

setup = {
    "model": "models/gemini-3.1-flash-live-preview",
    "system_instruction": {"parts": [{"text": "system prompt"}]},
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
            "description": "desc",
            "parameters": {
                "type": "OBJECT",
                "properties": {
                    "question": {
                        "type": "STRING",
                    }
                },
                "required": ["question"],
            },
        }]
    }],
}

try:
    c = CreateAuthTokenConfig(
        uses=1,
        live_connect_constraints=LiveConnectConstraints(
            model=setup["model"],
            config={
                "system_instruction": setup["system_instruction"],
                "generation_config": setup["generation_config"],
                "tools": setup["tools"]
            }
        )
    )
    print("Success!")
except Exception as e:
    print("Validation failed:", repr(e))
