import sys
sys.path.append("/home/suhailps/latest_claude/ayma/functions/bootstrap")
from main import _build_system_prompt

profile = {
    "display_name": "Test User",
    "agent_name": "Ayma",
    "community_profile": "dating_standard",
    "wiki_about_me": "I like hiking."
}
prompt = _build_system_prompt(profile, [], [])
print(prompt[:500])
