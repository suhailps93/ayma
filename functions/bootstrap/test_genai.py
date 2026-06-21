import os
from google import genai
from google.genai import types

client = genai.Client()

with open("prompts/MATCHMAKER_SKILL.txt", "r") as f:
    skill = f.read().replace("{agent_name}", "Ayma")

try:
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents="Are you a language model trained by Google?",
        config=types.GenerateContentConfig(
            system_instruction=skill,
        )
    )
    print("RESPONSE:", response.text)
except Exception as e:
    print("ERROR:", e)
