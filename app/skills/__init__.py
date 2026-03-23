from pathlib import Path

SKILLS_DIR = Path(__file__).parent


def load_system_skills() -> str:
    """Load all system skill files and return as a single concatenated string.
    Called once at agent startup — same content for every user.
    """
    system_dir = SKILLS_DIR / "system"
    skills = []
    for path in sorted(system_dir.glob("*.md")):
        skills.append(path.read_text().strip())
    return "\n\n".join(skills)


async def load_user_skills(user_id: str, supabase_client) -> str:
    """Load enabled user skill rows from DB for a specific user.
    Returns empty string if user has no skills configured.
    """
    result = (
        supabase_client.table("user_skills")
        .select("name, content")
        .eq("user_id", user_id)
        .eq("enabled", True)
        .execute()
    )
    if not result.data:
        return ""
    skills = [row["content"].strip() for row in result.data]
    return "\n\n".join(skills)
