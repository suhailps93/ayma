import asyncio
import json
import os
import sys

from main import _gemini_call, CONSOLIDATED_POST_TURN_PROMPT, TEXT_MODEL

async def main():
    prompt = CONSOLIDATED_POST_TURN_PROMPT.format(
        conversation="USER: I love reading sci-fi and I am currently in London. Also my favorite color is blue.",
        user_name="Alice",
        wiki_about_me="- She is 25 years old",
        wiki_context="(empty)",
        wiki_preferences="(empty)",
        wiki_matching="(empty)",
        field_catalog="- location_city: What city do you live in?",
        unanswered_questions_list="- color: What is your favorite color?",
        narrative_prompts_list="(all narrative prompts answered — no action needed)",
    )
    
    try:
        raw = await _gemini_call(
            TEXT_MODEL, prompt,
            generation_config={"response_mime_type": "application/json"},
        )
        print("RAW RESPONSE:")
        print(raw)
        data = json.loads(raw)
        print("PARSED OK!")
        print(json.dumps(data, indent=2))
    except Exception as e:
        print("ERROR:", e)

asyncio.run(main())
