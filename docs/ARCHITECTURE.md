# Ayma System Architecture

## Overview

Ayma is a serverless AI matchmaking platform. A Flutter mobile app talks directly to Gemini Live for real-time voice conversation. A minimal Cloud Run function handles auth-gated bootstrap and memory synthesis. All persistence lives in Firebase (Firestore + Storage).

---

## Component Map

```
Flutter App
  ├── Firebase Auth  (sign-in / ID token)
  ├── Firestore SDK  (profile, matches, notifications, media, traits)
  ├── Firebase Storage SDK  (photo uploads — direct, no backend)
  └── Gemini Live WebSocket  (voice AI — direct, no backend relay)
        └── FunctionDeclaration: save_trait  →  Firestore /users/{uid}/traits/

Cloud Run  (ayma-bootstrap)
  ├── POST /bootstrap  →  verify Firebase token → build system prompt → return WS URL + key
  ├── POST /post-turn  →  Gemini text fact extraction → Firestore /users/{uid}/memories/
  └── POST /run-matching  →  [PLANNED] heuristic filter → PII-stripped LLM scoring → write matches
```

---

## Data Flow: Voice Session

1. Flutter calls `POST /bootstrap` with Firebase ID token.
2. Cloud Run verifies token, fetches profile + memories + skills from Firestore, builds system prompt, returns Gemini Live WS URL + API key + setup payload.
3. Flutter opens WebSocket directly to `wss://generativelanguage.googleapis.com/ws/...?key=API_KEY`.
4. Sends `{"setup": {..., "tools": [{"functionDeclarations": [save_trait]}]}}`.
5. Audio streams bidirectionally: Flutter mic → Gemini Live → Flutter speakers.
6. When Gemini learns a user trait mid-conversation, it calls `save_trait(category, fact)`.
7. Flutter handles the tool call → writes to Firestore `users/{uid}/traits/{id}` immediately.
8. On `turnComplete`, Flutter calls `POST /post-turn` for supplementary text-based memory extraction.

---

## Data Flow: Text Session (fallback)

1. Flutter sends text via `sendText()`.
2. `audio_service.dart` calls Gemini REST (`gemini-2.5-flash`) with full conversation history.
3. Response appended to transcript; `POST /post-turn` called for memory extraction.

---

## Firestore Collections

```
users/{uid}
  display_name, profile_public, profile_private, profile_ai_observations
  agent_name, voice_preference, matching_prefs (map)
  age, gender, location_region
  onboarding_complete, matching_paused

users/{uid}/memories/{id}        ← text blobs from /post-turn (supplementary)
  text, session_id, created_at

users/{uid}/traits/{id}          ← structured facts from save_trait function calls (primary)
  category, fact, session_id, created_at

users/{uid}/skills/{id}
  name, content, enabled

matches/{id}
  user_a, user_b, score, rationale, status, created_at, updated_at

notifications/{id}
  user_id, type, title, body, meta, read, created_at

media/{id}
  user_id, photo_url, caption, created_at
```

---

## Models

| Model | Used For |
|---|---|
| `gemini-3.1-flash-live-preview` | Real-time voice conversation (Gemini Live WebSocket) |
| `gemini-2.5-flash` | Text fallback chat + post-turn memory extraction |
| `gemini-2.5-flash` (planned) | Matching compatibility scoring |

---

## Deployed Infrastructure

| Resource | Value |
|---|---|
| Firebase project | `ayma-ai` |
| Cloud Run URL | `https://ayma-bootstrap-235381544962.us-central1.run.app` |
| Cloud Run SA | `vertex-express@ayma-ai.iam.gserviceaccount.com` |
| Firestore | `us-central1` (default DB) |
| Storage bucket | `ayma-ai.firebasestorage.app` |

---

## Privacy Notes

- The `/bootstrap` system prompt includes real name, age, gender, location for the conversational AI companion — this is intentional.
- **Any future matching LLM call must strip PII** (name, exact location, employer) before sending profiles to the scoring model. See planned `/run-matching` endpoint.
- API key is returned to authenticated clients — acceptable for internal app. Replace with Vertex AI short-lived tokens before public release.

---

## Roadmap

### Phase 1 — Conversation & Memory (current focus)
- [x] Gemini Live WebSocket direct from Flutter
- [x] `/bootstrap` endpoint — system prompt + creds
- [x] `/post-turn` endpoint — text fact extraction → memories
- [ ] `save_trait` FunctionDeclaration in Gemini Live setup
- [ ] Flutter tool call handler → write to `users/{uid}/traits/`
- [ ] System prompt instructs model to use `save_trait` silently
- [ ] Firestore `traits` subcollection rule
- [ ] Surface traits in Insights screen

### Phase 2 — Matching Engine (done)
- [x] `/run-matching` endpoint — heuristic Firestore filter → PII-strip → LLM score → write matches
- [x] Trigger matching on demand from Flutter (button in Matches screen)
- [x] Match detail screen with score + reasoning + both user profiles

### Phase 3 — Vibe Check
- [ ] `/vibe-check` endpoint — agent-to-agent simulation loop (4-5 turns) → synergy score
- [ ] Wire vibe check into matching pipeline as a second-stage filter
