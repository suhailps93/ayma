# Matching System

> **Status:** Phase 2 — not yet implemented. Firestore schema and read side are ready.
>
> [← Back to Architecture](ARCHITECTURE.md)

---

## Overview — Three Stages

```
Stage 1  Firestore heuristic filter  →  candidate pool
Stage 2  PII-stripped LLM scoring    →  top matches written to Firestore
Stage 3  Agent-to-agent vibe check   →  synergy score (user-triggered only)
```

All stages run on Cloud Run (single `ayma-bootstrap` service). No separate matching service needed.

---

## Stage 1 — Heuristic Filter

**Endpoint:** `POST /run-matching` (planned, `functions/bootstrap/main.py`)
**Cost:** Near-zero (Firestore reads only)

Query Firestore `users` collection with hard filters:
- `onboarding_complete == true`
- `gender == preferred_gender` (from `matching_prefs.gender`)
- `age >= age_min AND age <= age_max` (from `matching_prefs.age_min/max`)
- Exclude current user and already-matched UIDs

Cap at 100 candidates before passing to Stage 2.

---

## Stage 2 — LLM Scoring

**Model:** `gemini-2.5-flash`
**Cost:** ~negligible per run (short profiles, small JSON output)

For each candidate (cap at 20 per run):
1. **Strip PII** — remove name, exact location, employer before sending to LLM
2. Send anonymized profiles of user + candidate to Gemini
3. Request structured JSON: `{ "compatibilityScore": 0–100, "reasoning": "one sentence" }`
4. Write matches with score ≥ 60 to Firestore `matches/{id}`

**Privacy rule:** Only public profile fields and AI observations are sent. Private notes (`profile_private`) are never sent to the scoring LLM.

**Match document schema:**
```
user_a     : uid
user_b     : uid
score      : int (0–100)
rationale  : string
status     : "pending" | "accepted" | "rejected" | "vibe_checked"
created_at : timestamp
updated_at : timestamp
```

---

## Stage 3 — Agent-to-Agent Vibe Check

**Endpoint:** `POST /vibe-check` (planned)
**Trigger:** User-triggered only (never automatic). Requires consent.

1. Fetch anonymized public profiles for both users
2. Simulate 4–5 dialogue turns alternating Agent A and Agent B
3. Score conversational synergy: `{ "synergyScore": 0–100, "summary": "one sentence" }`
4. Update `matches/{id}` with synergy score and status = `"vibe_checked"`

**Privacy rule:** Only public profile (`profile_public`) used — no private notes, no AI observations for the other person.

---

## When Matching Triggers

| Trigger | Stage | Notes |
|---------|-------|-------|
| User taps "Find matches" | 1 + 2 | Manual, immediate |
| After N new traits in a session | 1 + 2 | Planned: auto-trigger after 5+ new traits |
| User triggers vibe check | 3 only | Requires consent modal first |

---

## Roadmap

- [ ] Implement `POST /run-matching` in `main.py` (Stage 1 + 2)
- [ ] Flutter: "Find matches" button calls `/run-matching`
- [ ] Match detail screen: show score + reasoning
- [ ] Implement `POST /vibe-check` in `main.py` (Stage 3)
- [ ] Flutter: consent modal → call `/vibe-check` → show synergy result
- [ ] Auto-trigger matching after 5+ new traits written in a session
