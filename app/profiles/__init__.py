"""
Community profile loader.

The active profile is selected per-user via the community_profile column in user_profiles.
Default: dating_standard

Each profile defines required questions, deeper profile questions,
and matching preference questions. These are injected into the agent's
system prompt so it knows what to gather and in what priority order.
"""
from pathlib import Path
import yaml

PROFILES_DIR = Path(__file__).parent


def load_community_profile(profile_name: str = "dating_standard") -> dict:
    """Load a community profile YAML by name."""
    path = PROFILES_DIR / f"{profile_name}.yaml"
    if not path.exists():
        # Fall back to default rather than crashing
        path = PROFILES_DIR / "dating_standard.yaml"
    with open(path) as f:
        return yaml.safe_load(f)


def format_question_checklist(profile: dict, known_keys: set[str]) -> str:
    """
    Format the question checklist for injection into the system prompt.

    known_keys: set of question keys already answered (from Mem0 facts analysis).
    Items already known are marked ✓ so the agent skips them.
    """
    lines = ["## Information to gather\n"]

    lines.append("### Priority — get these first if not yet known")
    for item in profile.get("required", []):
        status = "✓ known" if item["key"] in known_keys else "○ needed"
        lines.append(f"  [{status}] {item['question']}")

    lines.append("\n### Deeper profile — build naturally through conversation")
    for item in profile.get("deeper", []):
        status = "✓ known" if item["key"] in known_keys else "○"
        lines.append(f"  [{status}] {item['question']}")

    lines.append("\n### Matching preferences — what they want in a match")
    for item in profile.get("matching_prefs", []):
        status = "✓ known" if item["key"] in known_keys else "○"
        lines.append(f"  [{status}] {item['question']}")

    return "\n".join(lines)
