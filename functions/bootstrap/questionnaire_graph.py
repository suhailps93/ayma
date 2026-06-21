"""
Ayma Questionnaire Graph
========================
Single source of truth for the matchmaking questionnaire: routing, hard filters,
heuristic weights, and LLM narrative prompts — per intent type.

Architecture (dual-engine, mirrors the Aimma schema design):

    [User Input]
         │
         ├──► PASS 1: Hard filter  (deterministic graph slicing)
         │           Global + intent-specific dealbreakers.
         │           A single mismatch eliminates the pair from the candidate pool.
         │
         ├──► PASS 2: Heuristic score  (weighted scalar distance)
         │           Ordinal/slider fields scored and weighted per intent type.
         │           Produces a float used to rank the filtered pool.
         │
         └──► PASS 3: LLM semantic score  (Gemini + pgvector cosine similarity)
                      Open narrative answers are embedded (gemini-embedding-2 →
                      vector(1536)) and stored in users.matching_embedding.
                      Gemini evaluates narrative tension/affinity for the top-N pairs.

Questionnaire Routing Graph
---------------------------

    [Onboarding]
         │
         ├──► GLOBAL fields (collected for everyone)
         │       name, age, gender_identity, location, interested_in,
         │       age_min/max, photos
         │
         └──► Intent select  ──►  routes to deep layer
                   │
                   ├── casual        ──►  Layer A fields + casual LLM prompts
                   ├── long_term     ──►  Layer B fields + long-term LLM prompts
                   ├── friends_bff   ──►  BFF fields   + BFF LLM prompt
                   ├── career_network──►  Career fields + career LLM prompt
                   └── nikah         ──►  Layer C fields (+ inherits Layer B)
                                          + nikah LLM prompts

Storage contract
----------------
- Scalar fields (hard filters + heuristic weights) → users.matching_prefs  (JSONB)
- Open narrative answers                           → users.profile_answers  (JSONB)
- Embedding vector                                 → users.matching_embedding (vector 1536)
"""

from enum import Enum
import json
from pathlib import Path


# ─────────────────────────────────────────────────────────────────────────────
# Intent types  (maps 1:1 to CommunityProfile ids in the Flutter app)
# ─────────────────────────────────────────────────────────────────────────────

class IntentType(str, Enum):
    CASUAL        = "casual"         # Short-term / dating / fluid connection
    LONG_TERM     = "long_term"      # Soulmate / life partner
    FRIENDS_BFF   = "friends_bff"    # Platonic friendship / "Find Your People"
    CAREER_NETWORK= "career_network" # Cofounder / collaborator / professional
    NIKAH         = "nikah"          # Sacred / Islamic marriage


# ─────────────────────────────────────────────────────────────────────────────
# PASS 1 — Hard Filters
# ─────────────────────────────────────────────────────────────────────────────

# Applied to every pair regardless of intent.
# A mismatch on any field below = skip the pair entirely.
GLOBAL_HARD_FILTERS: list[str] = [
    "gender_identity",   # must satisfy partner's interested_in
    "interested_in",     # must satisfy partner's gender_identity
    "age",               # each side's age must fall inside the other's age_min/age_max
    "location_radius_km",# Haversine distance must fit within both radii
]

# Additional dealbreakers that only activate for a specific intent.
INTENT_HARD_FILTERS: dict[IntentType, list[str]] = {
    IntentType.CASUAL: [
        # Casual is the most open intent — no extra hard filters.
    ],
    IntentType.LONG_TERM: [
        "children_intent",               # childfree ↔ wants-children = hard mismatch
        "partner_relocation_willingness",# both unwilling + distance > 0 = hard mismatch
    ],
    IntentType.FRIENDS_BFF: [
        # No extras beyond global.
    ],
    IntentType.CAREER_NETWORK: [
        "career_stage",  # e.g. "pre-revenue founder" must match with similar stage
    ],
    IntentType.NIKAH: [
        "religion",            # both must be Muslim
        "dietary_halal",       # halal requirement cannot be waived
        "riba_free_finance",   # Islamic finance requirement
        "polygyny_stance",     # seeker ↔ open/seeker; monogamy ↔ monogamy
    ],
}


# ─────────────────────────────────────────────────────────────────────────────
# PASS 2 — Heuristic Scoring Weights
# ─────────────────────────────────────────────────────────────────────────────
# Each tuple: (field_key, weight)
# Weights within each intent type must sum to 1.0.
# Ordinal/slider values are normalised to [0, 1] before distance scoring.

INTENT_HEURISTIC_WEIGHTS: dict[IntentType, list[tuple[str, float]]] = {
    IntentType.CASUAL: [
        ("spontaneity_index",      0.25),  # slider 1–10
        ("social_energy_baseline", 0.25),  # slider 1–10
        ("communication_density",  0.20),  # ordinal: constant / daily / logistics
        ("financial_split_pref",   0.15),  # ordinal: 50/50 / alternating / initiator pays
        ("substance_alcohol",      0.15),  # ordinal: never / social / weekly / heavy
    ],
    IntentType.LONG_TERM: [
        ("financial_axis",         0.20),  # slider: frugal ↔ experiential spender
        ("children_timeline",      0.20),  # ordinal: 1-3yr / 4-7yr / open / no
        ("family_involvement_idx", 0.15),  # slider: independent ↔ intergenerational
        ("financial_comingling",   0.15),  # ordinal: unified / hybrid / separate
        ("career_integration",     0.10),  # hustle / balanced / early-retire
        ("circadian_rhythm",       0.10),  # lark / standard / night owl
        ("domestic_order_index",   0.10),  # slider: minimalist ↔ organic chaos
    ],
    IntentType.FRIENDS_BFF: [
        ("social_energy_baseline", 0.35),
        ("spontaneity_index",      0.30),
        ("circadian_rhythm",       0.20),
        ("substance_alcohol",      0.15),
    ],
    IntentType.CAREER_NETWORK: [
        ("career_stage",           0.35),
        ("career_integration",     0.35),
        ("financial_axis",         0.30),
    ],
    IntentType.NIKAH: [
        ("salah_frequency",        0.35),  # highest weight: theological compatibility
        ("madhhab_adherence",      0.20),
        ("modesty_self",           0.15),
        ("modesty_requirement",    0.10),
        ("free_mixing_boundary",   0.10),
        ("wali_involvement",       0.05),
        ("mahr_philosophy",        0.05),
    ],
}


# ─────────────────────────────────────────────────────────────────────────────
# PASS 3 — LLM Narrative Prompts
# ─────────────────────────────────────────────────────────────────────────────
# Answers are stored in users.profile_answers[id] and embedded into
# users.matching_embedding for cosine similarity search via pgvector.

INTENT_LLM_PROMPTS: dict[IntentType, list[dict]] = {
    IntentType.CASUAL: [
        {
            "id":            "casual_vibe",
            "prompt":        (
                "Describe the perfect unstructured Saturday night encounter with a new match. "
                "Focus on the vibe, environment, and sensory details — no filtering."
            ),
            "system_utility": (
                "Embeds aesthetic alignment, energy profile, and implicit spending threshold."
            ),
        },
        {
            "id":            "casual_spark",
            "prompt":        (
                "What is a highly niche topic, weird hobby, or controversial pop-culture hill "
                "you're prepared to die on?"
            ),
            "system_utility": (
                "Extracts conversational spark triggers for Ayma-driven icebreakers."
            ),
        },
    ],

    IntentType.LONG_TERM: [
        {
            "id":            "lt_crisis_response",
            "prompt":        (
                "Imagine a severe external crisis hits your family 10 years from now — "
                "financial loss, unexpected relocation, health emergency. Describe how you "
                "and your ideal partner handle it together, behind closed doors."
            ),
            "system_utility": (
                "Vectorises vulnerability markers, resilience profile, and shadow attachment dynamics."
            ),
        },
        {
            "id":            "lt_growth",
            "prompt":        (
                "What version of yourself are you actively leaving behind, and how does your "
                "ideal future partner help support that transformation?"
            ),
            "system_utility": (
                "Identifies personal growth trajectory for long-term developmental compatibility."
            ),
        },
    ],

    IntentType.FRIENDS_BFF: [
        {
            "id":            "bff_dynamic",
            "prompt":        (
                "Describe your ideal friendship dynamic: how often you hang out, what you do, "
                "and how you show up for each other when life gets hard."
            ),
            "system_utility": (
                "Embeds friendship cadence, loyalty markers, and shared ritual preferences."
            ),
        },
    ],

    IntentType.CAREER_NETWORK: [
        {
            "id":            "career_vision",
            "prompt":        (
                "Describe the problem you're working on or want to work on, and the kind of "
                "co-founder or collaborator who would accelerate you the most — skills, "
                "working style, and energy."
            ),
            "system_utility": (
                "Captures complementary skill demand, working-style fit, and ambition alignment."
            ),
        },
    ],

    IntentType.NIKAH: [
        {
            "id":            "nikah_deen_dunya",
            "prompt":        (
                "How do you envision balancing Islamic spiritual goals — Hajj, continuous "
                "learning, teaching children — with your worldly career and personal ambitions?"
            ),
            "system_utility": (
                "Detects spiritual-material alignment; filters superficial compliance from "
                "lived lifestyle commitments."
            ),
        },
        {
            "id":            "nikah_household",
            "prompt":        (
                "How do you define the roles and responsibilities of a husband and wife "
                "managing a household? Be specific: financial maintenance, emotional labor, "
                "and leadership structure."
            ),
            "system_utility": (
                "Evaluates traditional vs. egalitarian marital contract interpretations to "
                "prevent acute structural friction."
            ),
        },
    ],
}


# ─────────────────────────────────────────────────────────────────────────────
# Field inventory per intent  (used by Ayma to know what to ask about)
# ─────────────────────────────────────────────────────────────────────────────

# Collected during onboarding for every user, regardless of intent.
GLOBAL_FIELDS: list[str] = [
    "name", "age", "gender_identity", "location_city",
    "location_lat", "location_lon", "location_radius_km",
    "interested_in", "age_min", "age_max", "photos",
]

# Fields collected only for users with the given intent.
# Nikah inherits all Long-Term fields plus its own theological layer.
INTENT_SPECIFIC_FIELDS: dict[IntentType, list[str]] = {
    IntentType.CASUAL: [
        "spontaneity_index", "social_energy_baseline",
        "communication_density", "financial_split_pref",
        "substance_alcohol", "substance_smoking",
    ],
    IntentType.LONG_TERM: [
        "financial_axis", "career_integration", "financial_comingling",
        "children_intent", "children_timeline",
        "family_involvement_idx", "parenting_ideology",
        "circadian_rhythm", "domestic_order_index",
        "attachment_style", "cognitive_processing",
        "communication_conflict_style",
        "partner_relocation_willingness",
    ],
    IntentType.FRIENDS_BFF: [
        "social_energy_baseline", "spontaneity_index",
        "circadian_rhythm", "substance_alcohol", "pet_owners",
    ],
    IntentType.CAREER_NETWORK: [
        "career_stage", "career_integration", "financial_axis",
        "occupation", "education_level",
    ],
    IntentType.NIKAH: [
        # Theological layer
        "religion", "islamic_sect", "madhhab_adherence", "salah_frequency",
        "dietary_halal", "riba_free_finance",
        "modesty_self", "modesty_requirement",
        "free_mixing_boundary", "wali_involvement",
        "mahr_philosophy", "polygyny_stance",
        # Inherits Long-Term layer
        "children_intent", "children_timeline", "family_involvement_idx",
        "parenting_ideology", "financial_axis", "financial_comingling",
        "partner_relocation_willingness",
    ],
}


# ─────────────────────────────────────────────────────────────────────────────
# Helpers used by the matching engine in main.py
# ─────────────────────────────────────────────────────────────────────────────

def get_hard_filters(intent: str) -> list[str]:
    """Return combined global + intent-specific hard-filter field names."""
    try:
        key = IntentType(intent)
    except ValueError:
        key = IntentType.LONG_TERM
    return GLOBAL_HARD_FILTERS + INTENT_HARD_FILTERS.get(key, [])


def get_heuristic_weights(intent: str) -> list[tuple[str, float]]:
    """Return ordered heuristic weight tuples for the given intent."""
    try:
        key = IntentType(intent)
    except ValueError:
        key = IntentType.LONG_TERM
    return INTENT_HEURISTIC_WEIGHTS.get(key, [])


def get_llm_prompts(intent: str) -> list[dict]:
    """Return the LLM narrative prompt descriptors for the given intent."""
    try:
        key = IntentType(intent)
    except ValueError:
        key = IntentType.LONG_TERM
    return INTENT_LLM_PROMPTS.get(key, [])


def all_fields_for_intent(intent: str) -> list[str]:
    """Return all fields (global + intent-specific) that should be populated."""
    try:
        key = IntentType(intent)
    except ValueError:
        key = IntentType.LONG_TERM
    return GLOBAL_FIELDS + INTENT_SPECIFIC_FIELDS.get(key, [])


# ─────────────────────────────────────────────────────────────────────────────
# Profile question catalog (questionnaire_schema.json)
# ─────────────────────────────────────────────────────────────────────────────

_SCHEMA_PATH = Path(__file__).parent / "questionnaire_schema.json"


def load_profile_schema() -> dict:
    """Load the full profile question catalog, community configs, and storage policy."""
    return json.loads(_SCHEMA_PATH.read_text())


def get_profile_questions() -> list[dict]:
    return load_profile_schema().get("questions", [])


def get_community_extra_questions() -> list[dict]:
    return load_profile_schema().get("community_extra_questions", [])


def get_community_config() -> dict:
    return load_profile_schema().get("communities", {})


def get_public_payload_order() -> list[str]:
    schema = load_profile_schema()
    return schema.get("profile_storage_policy", {}).get("public_profile_payload_order", [])
