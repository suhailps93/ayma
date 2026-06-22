# Ayma — Canonical Cross-Agent Plan

> **Canonical doc rule:** `PLAN.md` is the only authoritative shared execution plan for this repo.
> Every agent (`Codex`, `Claude`, `Gemini`, `DeepSeek`, or any future agent) must:
> 1. read this file before making changes,
> 2. continue from the current checklist instead of starting a new plan elsewhere,
> 3. update this file before handing off.
>
> **Handoff rule:** if work stops mid-stream, record:
> - what changed,
> - what was verified,
> - what is still blocked,
> - the exact next step.
>
> **No parallel plan docs:** `docs/agent.md`, `CLAUDE.md`, `ayma_flutter/AGENTS.md`, and any tool-specific docs are implementation supplements only. They must defer to this file.

> **Rule:** Do ONE step at a time. Do not move to the next step until the current one works
> and you understand why it works — not just that it works.
>
> **Client Boundary:** Keep the client as thin as possible. The web app and Flutter app should
> only handle presentation, device capabilities (mic/camera/playback), and authenticated API /
> WebSocket calls. Auth, session lifecycle, profile writes, matching logic, location lookup,
> and all business logic belong in the backend.
>
> **Goal:** Build a production-grade personalized AI matchmaking platform, and understand
> every layer of the architecture as we go.

---

## Current Branch Reality

This repo is in an active transition state.

- The Flutter app remains the user-facing client in `ayma_flutter/`.
- The active backend for profile/bootstrap/matching work is `functions/bootstrap/main.py`.
- The backend stores all application data in PostgreSQL via `DATABASE_URL`.
- Community-specific onboarding and question selection are in progress and partially implemented on this branch.
- Some older docs still describe Supabase, Mem0, or old local-backend flows. Treat those as stale unless they are explicitly reconciled here.

### Current production-readiness priorities

- [ ] Stabilize the new community-profile onboarding flow end-to-end
- [ ] Keep backend question seeding, post-turn extraction, and profile metadata aligned with community selection
- [x] Reconcile stale architecture/testing docs with the actual branch state
- [ ] Re-establish repeatable validation commands for backend, Flutter analysis, and emulator/device runs
- [ ] Run emulator or device-based smoke coverage for onboarding, chat, profile, matches, notifications

### Current verified status on this branch

- [x] Broken onboarding file from prior agent repaired
- [x] `community_profile` persists from Flutter onboarding
- [x] Backend bootstrap now seeds questions from community-specific question sets
- [x] Removed automatic SQLite fallback on Postgres connection failure (`main.py` lifespan now requires Postgres unless `USE_MOCK_DB=true`)
- [x] Onboarding `location_coords` now persists through backend profile update path
- [x] Server no longer treats onboarding-populated age/gender/location/age-range as unanswered on first bootstrap
- [x] Flutter completeness scoring now respects community-specific question sets
- [x] Community selection now affects backend prompt style as well as question seeding
- [x] Backend test suite now checks Flutter/backend community profile config drift
- [x] Added `adb`-based UI fallback helper for emulator/device inspection when flutter-skill is unavailable
- [x] Fixed first-time `/profile` writes so onboarding no longer drops data when the user row does not exist yet
- [x] `python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/mock_db.py` passes
- [x] `python3 -m unittest functions/bootstrap/test_main_logic.py` passes
- [x] Cloud Run redeployed with upsert fix (revision 00013); Postgres required via `DATABASE_URL`
- [x] Emulator smoke pass: all 8 screens pass (chat, matches, explore, signals, profile-public, profile-private, settings, onboarding-flow)
- [x] Onboarding submit confirmed landing on /chat (upsert fix verified in production)
- [x] `FirestoreService` renamed to `ApiService` across all 10 consumer files
- [x] `cloud_firestore` removed from pubspec.yaml (was unused — all data goes through backend HTTP)
- [x] Dockerfile includes `mock_db.py` (for explicit `USE_MOCK_DB=true` local dev only — not used on Cloud Run)
- [x] Stale docs/agent.md updated (removed Firestore schema, updated service names, added postgres schema reference)
- [x] Bad-named doc `# Ayma: Production-Scale Matchmaking OS.md` removed (superseded by `docs/ARCHITECTURE.md`)
- [ ] `flutter analyze` re-run on this branch (Flutter CLI unavailable in agent shell)
- [ ] Text chat integration test (adb cannot type into Flutter TextField; requires device keyboard or flutter_driver)

### Current environment blockers observed

- Flutter CLI is not available on this shell `PATH`
- Android emulator binary exists at `/home/suhailps/Android/Sdk/emulator/emulator`
- Emulator launch from this shell currently fails with missing runtime library visibility:
  `libX11.so.6: cannot open shared object file`
- Hidden snap paths and some home subdirectories are not readable from this agent shell, so Flutter/emulator invocation may need to happen from a non-sandboxed user shell even when code edits happen here

---

## Cross-Agent Workflow

All agents must follow this sequence:

1. Read `PLAN.md` first.
2. Read the nearest supplemental doc only after that:
   - repo-wide context: `docs/agent.md`
   - Flutter-specific context: `ayma_flutter/AGENTS.md` or `ayma_flutter/CLAUDE.md`
3. Check current uncommitted work with `git status --short`.
4. Continue the active checklist below instead of inventing a new one.
5. After code or docs changes:
   - update validation status in this file,
   - update blockers if anything failed,
   - append runtime test notes to `ayma_flutter/testing-lessons.md` when UI testing was attempted.

### Handoff template

When stopping, append/update these items in this file:

- `Last completed`
- `Validated`
- `Blocked on`
- `Next action`

---

## Active Workstream

### Workstream A — Community Onboarding Rollout

- [x] Repair broken onboarding UI file and restore app structure
- [x] Add community selection step to onboarding
- [x] Persist `community_profile` from Flutter to backend profile update
- [x] Add backend community-aware question seeding
- [x] Persist onboarding `location_coords`
- [x] Prevent server-side reseeding of onboarding-known fields as unanswered
- [x] Apply community-specific backend prompt behavior
- [x] Add automated guard against Flutter/backend community config drift
- [ ] Ensure question definitions are sourced consistently across Flutter and backend from a single source
- [ ] Validate existing users with legacy `dating_standard` still behave correctly
- [ ] Verify post-turn extraction and structured wiki behavior for community-only fields

### Workstream B — Production Readiness

- [x] Identify stale docs that conflict with current architecture
- [x] Bring core docs in line with actual backend/client architecture
- [x] Re-run backend validation after each backend change
- [x] Establish a passing emulator/device smoke checklist (all major screens verified)
- [x] Remove unused `cloud_firestore` package from pubspec.yaml
- [x] Remove misleading `FirestoreService` name (renamed to `ApiService`)
- [x] Dockerfile includes `mock_db.py` for opt-in local dev only
- [x] Rename bad-named doc file
- [x] Re-run Flutter static validation (`flutter analyze`) — completed: 0 issues found.
- [x] Remove or quarantine any remaining obsolete artifacts (deleted stale docs: data.md, memory.md, matching.md, app_audit_and_data_map.md, laptop_backend_server.md, pixel_wifi_test_runbook.md)

### Workstream C — Shared Agent Discipline

- [x] Ensure all agent entrypoint docs explicitly defer to `PLAN.md`
- [ ] Ensure testing instructions point back to shared validation state here
- [ ] Keep this file updated on every handoff

---

## Validation Matrix

Use this matrix instead of ad hoc “seems fine” validation.

### Backend

- [x] `python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/mock_db.py`
- [x] `python3 -m unittest functions/bootstrap/test_main_logic.py`
- [x] Backend endpoint smoke test — Cloud Run revision 00013 responds correctly
- [ ] Matching endpoint smoke test (needs 2+ users with profiles)
- [ ] Existing test suite run, if/when tests are added

### Flutter static

- [x] `flutter pub get`
- [x] `flutter analyze`
- [ ] `dart format --output=none --set-exit-if-changed .`

### Flutter runtime

- [x] App running on emulator-5554 (installed build includes community selection)
- [ ] Rebuild app from current source (Flutter CLI required)
- [x] Smoke onboarding flow — all 4 steps + submit → /chat PASS
- [x] Smoke auth — Firebase auth active, profile persists after onboarding
- [ ] Smoke chat/text (adb cannot inject into Flutter TextField; pending device test)
- [ ] Smoke live voice (pending physical device)
- [x] Smoke profile (public/private tabs, completeness progress bar, photo upload button)
- [x] Smoke matches (correct empty state)
- [x] Smoke notifications/signals (correct empty state)

### Required evidence before calling work “production ready”

- Passing backend static validation
- Passing Flutter static validation
- At least one real runtime pass on emulator or physical device after latest code changes
- Updated `testing-lessons.md`
- Updated handoff notes in this file
- If flutter-skill tools are unavailable in-session, use `ayma_flutter/scripts/adb-ui` as the minimum UI inspection fallback and record that in testing notes

---

## Runtime Test Checklist

When a runnable Android environment is available, execute in this order:

Detailed screen-by-screen steps live in `docs/ui_test_plan.md`.

1. Start emulator or connect test device.
2. Launch the app from `ayma_flutter/`.
3. Verify:
   - auth route handling,
   - onboarding including community selection,
   - post-onboarding redirect,
   - profile persistence,
   - question fetch behavior,
   - chat open/load,
   - matches screen load,
   - notifications screen load.
4. Record pass/fail in `ayma_flutter/testing-lessons.md`.
5. Update this file’s validation matrix.

Current emulator-specific note:
- The latest installed build on `emulator-5554` does include the new community step.
- A real runtime regression was reproduced during onboarding submit: the app returned to onboarding welcome instead of landing on chat.
- Root cause identified in source: backend `/profile` endpoint only ran `UPDATE`, so first-time users without an existing `users` row silently lost onboarding writes.
- Source fix and regression test are now in place; the runtime pass must be repeated against a backend process that includes this patch.

---

## Handoff State

- Last completed: Overhauled the custom raw WebSocket streaming setup with a unified LiveKit Cloud and LiveKit Agents framework. Integrated the LiveKit Agent Server programmatically into FastAPI lifespan. Created the backend Agent worker in `agent.py` to manage real-time voice (Gemini Live) and text chat (LiveKit Data Channels) using a shared `ChatContext` and database connection. Refactored the client-side `AymaAudioService` using the `livekit_client` Flutter SDK to connect natively to LiveKit Rooms, enable local microphone tracking with AEC, handle remote audio playback automatically, map text chat to `localParticipant.publishData`, and mute/unmute tracks to support clean user interruptions.
- Validated: `dart analyze` passes with 0 errors and 0 warnings. Backend Python code compiles and all 19 unittest test cases in `test_main_logic.py` pass successfully.
- Blocked on: Physical device connection tests for LiveKit room session.
- Next action: Test end-to-end LiveKit voice and text chat session on a physical mobile device.

---

## What We Are Building (Plain English)

Ayma is a matchmaking app where:
- Each user talks to their own personal AI agent (text or voice)
- The agent learns who the user is over time and writes their profile automatically
- The system quietly matches users in the background using a two-stage process
- When a match looks good, users can let their two AI agents have a conversation first
- Profiles have three layers: what others see, what only the user sees, and what only the AI sees

---

## Architecture at a Glance

```
User (Flutter App)
      |
      | HTTP REST & WebSocket (Gemini Live)
      v
FastAPI Backend  <-- functions/bootstrap/main.py
      |
      |-- Gemini API       <-- the AI brain per user
      |-- Firebase Auth    <-- authentication
      |
      v
PostgreSQL  <-- all data (users, messages, matches, pgvector for embeddings)
```

---

## The Checklist

Each step has:
- What to build
- What you should understand after finishing it
- Alternatives we considered and why we chose what we chose

---

### PHASE 0 — Scaffold ✅

- [x] **Step 0.1** — Set up Flutter app (`ayma_flutter/`) and FastAPI backend (`functions/bootstrap/main.py`)
- [x] **Step 0.2** — Configure Firebase Auth and Postgres connection
- [x] **Step 0.3** — Run the scaffold locally, understand the folder structure

---

### PHASE 1 — Data Layer (PostgreSQL + Firebase) ✅

- [x] **Step 1.1** — Set up PostgreSQL with pgvector
- [x] **Step 1.2** — Write and run migration: `users` table with profile columns
- [x] **Step 1.3** — Write and run migrations for `messages`, `matches`, `user_questions`
- [x] **Step 1.4** — Wire Firebase Auth into the backend for secure endpoint access

---

### PHASE 2 — Personalized Agent (Gemini) ✅

- [x] **Step 2.1** — Build dynamic system prompt generation based on user profile
- [x] **Step 2.2** — Build the `/chat` endpoint for text-based interactions
- [x] **Step 2.3** — Build the `/post-turn` synthesis pipeline (extracts facts and updates the structured profile)
- [x] **Step 2.4** — Implement semantic vector embeddings for user preferences

---

### PHASE 3 — Voice (Gemini Live) ✅

- [x] **Step 3.1** — Generate ephemeral Gemini Live tokens in `/bootstrap`
- [x] **Step 3.2** — Stream voice to Gemini Live using WebSocket
- [x] **Step 3.3** — Store voice preferences (e.g., Charon / Puck / Kore) in the profile

---

### PHASE 4 — Profile UI (Flutter)

- [x] **Step 4.1** — Profile page: display user information and AI-written summaries
- [x] **Step 4.2** — Onboarding flow with community selection
- [ ] **Step 4.3** — Profile completeness tracking and actionable missing fields
- [ ] **Step 4.4** — Settings → manage visibility of profile fields

---

### PHASE 5 — Matching Engine

- [ ] **Step 5.1** — Build Stage 1: dynamic SQL filter + pgvector soft-rank → top candidates
- [ ] **Step 5.2** — Build Stage 2: Gemini Flash scoring loop (structured JSON output)
- [ ] **Step 5.3** — Wrap Stage 1 + Stage 2 in scheduled jobs
- [ ] **Step 5.4** — Flutter: `Matches` screen with score, rationale, and action buttons

---

### PHASE 6 — Agent-to-Agent (Stage 3)

- [ ] **Step 6.1** — Build the Stage 3 agent prompts (public profile only, no leakage)
- [ ] **Step 6.2** — Build the summarizer — writes summaries separately to `matches`
- [ ] **Step 6.3** — Push notifications to Flutter when agent convo completes

---

### PHASE 7 — Polish

- [ ] **Step 7.1** — Rate limiting implementation per user/IP
- [ ] **Step 7.2** — Security hardening (CORS, token leakage prevention)
- [ ] **Step 7.3** — Cost guardrails and token budgeting
- [ ] **Step 7.4** — Observability and performance tracing

---

## Decisions and Alternatives (Reference)

| Decision | What we chose | Alternative considered | Why we chose ours |
|----------|--------------|----------------------|-------------------|
| Architecture | FastAPI + Gemini + Postgres | LangGraph + Supabase + Mem0 | Much simpler, fully custom logic, minimal dependencies, direct control over AI context. |
| Client | Flutter | React | Native performance, better device capability integration (mic/camera). |
| Auth | Firebase Auth | Supabase Auth | Seamless integration with mobile ecosystems. |
| Voice infra | WebSocket + Gemini Live | LiveKit + Deepgram | One service vs three; Google manages VAD, turn detection, interruption |
| Background jobs | Native Python Tasks / Cloud Tasks | Celery + Redis | No always-on worker/broker; fits stateless HTTP model |

---

## Costs at MVP Scale

| Service | Cost |
|---------|------|
| Firebase Auth | $0 (free tier) |
| Cloud Tasks | $0 (1M tasks/mo free) |
| Gemini API | ~$0–5/mo at low traffic |
| PostgreSQL | ~$0–10/mo (managed) |
| **Total** | **~$0–15/mo** |

---

## Current Step

**-> Address Security Fixes Needed**

Thin-client architecture is the active rule. Fix the security issues below before building new features.

---

## Deferred Follow-Up

- [ ] **Admin console deployment wiring** — The password-only `/admin` UI and backend endpoints are implemented locally, but production access is still blocked by backend environment/deployment work. Finish this later by:
  set `ADMIN_PASSWORD` on the real backend that owns live Postgres data;
  redeploy/restart that backend;
  verify `/admin` works from signed-out and signed-in states;
  optionally add a local-backend run path once a real `DATABASE_URL` is available for local testing.

---

## Security Fixes Needed

> Audited: 2026-06-20. Fix all Critical and High items before production launch.

| Severity | Location | Issue | Fix |
|---|---|---|---|
| Critical | `functions/bootstrap/main.py:828` | Raw Google API key (`GOOGLE_API_KEY`) returned directly to the Flutter client in the `"token"` field of the bootstrap response. Any authenticated user can extract this key and make unlimited calls to all Gemini services with no per-user quota enforcement. | Replace with short-lived ephemeral credentials. Use Gemini's token generation endpoint or a Firebase App Check–gated token exchange. Never return the raw `GOOGLE_API_KEY` to any client. |
| Critical | `functions/bootstrap/main.py:168–173` | `allow_origins=["*"]` is combined with `allow_credentials=True`. The CORS spec prohibits this combination; browsers reject it, but the configuration is still invalid and signals a misconfigured security boundary. Any web client can attempt credentialed cross-origin requests. | Replace `allow_origins=["*"]` with an explicit allowlist of trusted origins (e.g. the Flutter app deep-link domain or any web admin panel). Remove `allow_credentials=True` if credentials are not needed from a browser context. |
| High | `functions/bootstrap/main.py:2260` | `/vibe-check` endpoint triggers 2–3 expensive LLM calls per request (conversation simulation + scoring) but has no `@limiter.limit()` decorator. Any authenticated user can call it in a tight loop, rapidly exhausting Gemini API quota. | Add `@limiter.limit(RATE_RUN_MATCHING)` (or a dedicated tighter limit) to `/vibe-check`. Also consider per-user-ID limiting in addition to IP-based limiting. |
| High | `functions/bootstrap/main.py:139` | `limiter = Limiter(key_func=get_remote_address)` — all rate limits are per source IP. Behind mobile carrier NAT, many real users share one IP and get collectively throttled. Conversely, an attacker with multiple IPs (VPN, cloud VMs) trivially bypasses the limit. | Add a second limiter key function that uses the authenticated `uid` for all endpoints that call `Depends(verify_token)`. Apply both IP and user-ID limits. |
| High | `functions/bootstrap/main.py:931–932` | `PostTurnRequest.messages: list[dict]` has no Pydantic schema on individual items. No constraint on `role` values, no max length on `text`, no cap on list length. A user can send arbitrary role values (e.g. `role="model"`) to poison the conversation history fed to Gemini, or send megabytes of text per call. | Define a `MessageItem(BaseModel)` with `role: Literal["user","model"]` and `text: str = Field(max_length=4000)`. Add `messages: list[MessageItem] = Field(max_items=50)` to `PostTurnRequest`. |
| High | `functions/bootstrap/main.py:1647–1673` | `MessageBody.text: str` in `POST /messages` has no length validation. A user can send a multi-megabyte DM body that gets stored in the DB and partially embedded in a push notification preview. | Add `text: str = Field(max_length=2000)` to `MessageBody`. |
| High | `functions/bootstrap/main.py:1412–1427` | `POST /profile/answers` accepts any `field_id` string. Unknown field IDs (not in `PROFILE_FIELD_META`) are stored as `sensitive=False` (public) by default. This allows users to inject arbitrary key-value pairs into their profile JSONB columns and mark them public, polluting downstream matching and LLM prompts. | Validate `field_id` against `PROFILE_FIELD_META` at the top of the handler: `if field_id not in PROFILE_FIELD_META: raise HTTPException(400, "Unknown field_id")`. |
| High | `functions/bootstrap/main.py:1165–1183` | `ProfileUpdateBody` fields `age`, `display_name`, `community_profile`, and `agent_name` have no Pydantic constraints (min/max, allowed values, max length). A user can set `age=-1` or `age=999`, a 10 000-character display name, or an invalid `community_profile` string that causes silent fallback to the full question bank. | Add `age: int = Field(None, ge=1, le=120)`, `display_name: str = Field(None, max_length=80)`, `agent_name: str = Field(None, max_length=40)`, and validate `community_profile` against `COMMUNITY_CONFIG.keys()`. |
| Medium | `functions/bootstrap/main.py:1466–1474` | `POST /questions/followup` accepts arbitrary text and inserts it verbatim into the `user_questions` table. The text is later embedded in the Gemini system prompt as a follow-up reminder. A user can inject adversarial instructions (e.g. `"IGNORE PREVIOUS INSTRUCTIONS…"`) that manipulate Ayma's behavior in future sessions. | Add `question: str = Field(max_length=300)` to `FollowupQuestionBody`. Strip or escape any content that looks like system-prompt control sequences before storing. |
| Medium | `storage.rules:5` | `allow read: if request.auth != null` on `media/{uid}/{allPaths=**}` allows any authenticated user to read any other user's media files, not just their own matches. A bad actor can enumerate and download all user photos. | Restrict reads to the owner or to users who have an active match with the media owner. At minimum, add `request.auth.uid == uid` as an alternative condition gated on a separate "match verified" lookup, or scope reads to `request.auth.uid == uid` and serve match media through a signed-URL API endpoint instead. |
| Medium | `firestore.rules:6` | `allow read: if request.auth != null && resource.data.onboarding_complete == true` lets any authenticated user read the full Firestore user document of any onboarded user. Depending on what fields are stored in Firestore, this can expose private profile data. | Tighten to `request.auth.uid == uid` for self-reads and provide an explicit, field-masked public-read rule that exposes only safe fields (e.g. `display_name`, `profile_public`). |
| Medium | `functions/bootstrap/main.py:1485–1508` | The `query` parameter in `GET /explore` is passed directly into an `ILIKE` clause with `%…%` wrapping. There is no length validation. Very long query strings cause expensive sequential scans and can degrade DB performance. The parameter is properly parameterized so SQL injection is not possible, but resource exhaustion is. | Add `query: str = Query(None, max_length=100)` in the function signature. |
| Medium | `functions/bootstrap/config.py:18–19` | The `DATABASE_URL` default value is `postgresql://postgres:postgres@localhost:5432/ayma` — a plaintext credential embedded in source code. If this default is ever reached in a non-local environment (e.g. a CI container without the env var set), it will attempt to connect with the default postgres superuser password. | Remove the default value entirely: `DATABASE_URL = os.environ["DATABASE_URL"]` (will raise `KeyError` at startup if unset, which is the correct fail-fast behavior). |
| Low | `functions/bootstrap/main.py:193` | `logger.info(f"FCM sent: {title!r} → {fcm_token[:20]}…")` logs the first 20 characters of an FCM device token. FCM tokens are sensitive; even a partial token should not appear in logs that may be exported to observability platforms. | Replace with `logger.info(f"FCM sent: {title!r} → [token redacted]")` or log only a hash of the token for correlation. |
