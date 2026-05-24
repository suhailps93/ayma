# Data Layer

> **Status:** Live on Firebase/Firestore. Supabase/PostgreSQL fully removed.
>
> [← Back to Architecture](ARCHITECTURE.md)

---

## Firestore Collections

All data lives in Firestore (project: `ayma-ai`, region: `us-central1`).

```
users/{uid}
  display_name          string
  profile_public        string   — bio shown to other users
  profile_private       string   — personal notes, only user can read
  profile_ai_observations string  — AI-written summary, shown in Insights
  agent_name            string   — custom name for the AI companion
  voice_preference      string   — Gemini Live voice (Charon, Puck, etc.)
  matching_prefs        map      — { age_min, age_max, gender, ... }
  age                   int
  gender                string
  location_region       string
  onboarding_complete   bool
  matching_paused       bool

users/{uid}/memories/{id}
  text        string   — free-text fact, extracted by /post-turn
  session_id  string
  created_at  timestamp

users/{uid}/traits/{id}
  category    string   — hobby | value | goal | personality | lifestyle | relationship | emotion | opinion | experience
  fact        string   — single concise sentence, extracted live by save_trait function call
  session_id  string
  created_at  timestamp

users/{uid}/skills/{id}
  name        string
  content     string
  enabled     bool

matches/{id}
  user_a      uid
  user_b      uid
  score       int      — 0–100, from LLM scoring
  rationale   string
  status      string   — pending | accepted | rejected | vibe_checked
  created_at  timestamp
  updated_at  timestamp

notifications/{id}
  user_id     uid
  type        string
  title       string
  body        string
  meta        map
  read        bool
  created_at  timestamp

media/{id}
  user_id     uid
  photo_url   string   — Firebase Storage download URL
  caption     string
  created_at  timestamp
```

---

## Who Reads/Writes What

| Data | Flutter client | Cloud Run |
|------|---------------|-----------|
| `users/{uid}` (own) | read + write | read |
| `users/{uid}` (others) | read if `onboarding_complete == true` | — |
| `users/{uid}/memories` | read only | write only |
| `users/{uid}/traits` | read + write | — |
| `users/{uid}/skills` | read + write | read |
| `matches` | read (participant only) | write (planned) |
| `notifications` | read + mark-read | write |
| `media` | read + write own | — |
| Firebase Storage | write own, read any | — |

---

## Security Rules

Enforced in `firestore.rules` (deployed to `ayma-ai`). Key rules:

- Own profile: full read/write
- Other profiles: read only if `onboarding_complete == true`
- `memories`: client read-only (Cloud Run writes)
- `traits`: client read/write own
- `matches`: read only if `user_a` or `user_b` == auth uid; no client writes
- `notifications`: read own; only `read` field can be updated by client
- `media`: read any authenticated user; write own only

---

## Firebase Storage

Bucket: `ayma-ai.firebasestorage.app`

Photos uploaded directly from Flutter → Storage (no backend relay). After upload, Flutter calls `FirestoreService.saveMediaRecord()` to write the download URL to the `media` collection.

Path pattern: `uploads/{uid}/{filename}`
