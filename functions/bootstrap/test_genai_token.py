import os
import json
from datetime import datetime, timezone, timedelta
from google import genai

key = os.environ.get("GOOGLE_API_KEY", "")

print("Testing with default v1...")
try:
    c1 = genai.Client(api_key=key)
    now = datetime.now(timezone.utc)
    t = c1.auth_tokens.create(config={"uses": 1, "expire_time": (now + timedelta(minutes=1)).isoformat()})
    print("Success:", t)
except Exception as e:
    print("Failed default:", repr(e))

print("\nTesting with v1alpha...")
try:
    c2 = genai.Client(api_key=key, http_options={"api_version": "v1alpha"})
    now = datetime.now(timezone.utc)
    t = c2.auth_tokens.create(config={"uses": 1, "expire_time": (now + timedelta(minutes=1)).isoformat()})
    print("Success:", t)
except Exception as e:
    print("Failed v1alpha:", repr(e))
