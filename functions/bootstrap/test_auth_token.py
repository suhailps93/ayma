import os
import json
from datetime import datetime, timezone, timedelta
from google import genai

key = os.environ.get("GOOGLE_API_KEY", "")

c = genai.Client(api_key=key, http_options={"api_version": "v1alpha"})
now = datetime.now(timezone.utc)
t = c.auth_tokens.create(config={"uses": 1, "expire_time": (now + timedelta(minutes=1)).isoformat()})
print("Token name:", t.name)
print("Token type:", type(t))
print("Token vars:", vars(t))
