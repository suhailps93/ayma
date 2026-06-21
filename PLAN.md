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
- The backend now targets PostgreSQL first, with a local SQLite mock fallback for local bootstrap.
- Community-specific onboarding and question selection are in progress and partially implemented on this branch.
- Some older docs still describe Supabase, Mem0, or old local-backend flows. Treat those as stale unless they are explicitly reconciled here.

### Current production-readiness priorities

- [ ] Stabilize the new community-profile onboarding flow end-to-end
- [ ] Keep backend question seeding, post-turn extraction, and profile metadata aligned with community selection
- [ ] Reconcile stale architecture/testing docs with the actual branch state
- [ ] Re-establish repeatable validation commands for backend, Flutter analysis, and emulator/device runs
- [ ] Run emulator or device-based smoke coverage for onboarding, chat, profile, matches, notifications

### Current verified status on this branch

- [x] Broken onboarding file from prior agent repaired
- [x] `community_profile` persists from Flutter onboarding
- [x] Backend bootstrap now seeds questions from community-specific question sets
- [x] SQLite fallback pool supports `executemany`
- [x] Onboarding `location_coords` now persists through backend profile update path
- [x] Server no longer treats onboarding-populated age/gender/location/age-range as unanswered on first bootstrap
- [x] Flutter completeness scoring now respects community-specific question sets
- [x] Community selection now affects backend prompt style as well as question seeding
- [x] Backend test suite now checks Flutter/backend community profile config drift
- [x] Added `adb`-based UI fallback helper for emulator/device inspection when flutter-skill is unavailable
- [x] Fixed first-time `/profile` writes so onboarding no longer drops data when the user row does not exist yet
- [x] `python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/mock_db.py` passes
- [x] `python3 -m unittest functions/bootstrap/test_main_logic.py` passes
- [x] Cloud Run redeployed with upsert fix (revision 00013, includes mock_db.py in Docker image)
- [x] Emulator smoke pass: all 8 screens pass (chat, matches, explore, signals, profile-public, profile-private, settings, onboarding-flow)
- [x] Onboarding submit confirmed landing on /chat (upsert fix verified in production)
- [x] `FirestoreService` renamed to `ApiService` across all 10 consumer files
- [x] `cloud_firestore` removed from pubspec.yaml (was unused — all data goes through backend HTTP)
- [x] Dockerfile updated to COPY mock_db.py (required for SQLite fallback in Cloud Run)
- [x] Stale docs/agent.md updated (removed Firestore schema, updated service names, added postgres schema reference)
- [x] Bad-named doc `# Ayma: Production-Scale Matchmaking OS.md` renamed to `docs/postgres_rearch_plan.md`
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
- [x] Fix Dockerfile to include mock_db.py
- [x] Rename bad-named doc file
- [x] Re-run Flutter static validation (`flutter analyze`) — completed: 0 issues found.
- [ ] Remove or quarantine any remaining obsolete artifacts

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

- Last completed: Ran `flutter analyze` (0 issues). Fixed signature bugs (`request` arg) in test logic and SQL `f-string` interpolation bug in `main.py` for `LIMIT {MATCH_CANDIDATE_POOL}` causing `sqlite3.OperationalError` during tests. Re-ran `unittest` and it fully passes. Ran `pipeline_test.py` end-to-end simulation.
- Validated: `python3 -m unittest functions/bootstrap/test_main_logic.py` (25 tests pass). `flutter analyze` reports `No issues found!`.
- Blocked on: `pipeline_test.py` hit `429 ResourceExhausted` (Gemini free tier quota limits) during the `Scoring Priya <-> Fatima` stage. Physical device testing is still required for voice/chat.
- Next action: Test text chat and voice on physical device; configure a paid Gemini API key or rotate keys to bypass the 429 quota exhaustion; review remaining audit gaps from `pipeline_test.py` (rate limiting, logging, etc.).

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
User (browser / CLI)
      |
      | WebSocket (text) or ADK Streaming (voice)
      v
Vertex AI Agent Engine  <-- our backend lives here
      |
      |-- LangGraph Agent  <-- the AI brain per user
      |-- Cloud Tasks      <-- background jobs (no Celery, no Redis)
      |
      v
Supabase  <-- all data (PostgreSQL + pgvector + Auth)
Mem0      <-- structured facts about each user
Graphiti/Kuzu  <-- relationship graph for matching
```

---

## The Checklist

Each step has:
- What to build
- What you should understand after finishing it
- Alternatives we considered and why we chose what we chose

---

### PHASE 0 — Scaffold ✅

- [x] **Step 0.1** — Install prerequisites and understand what `agent-starter-pack` gives us
- [x] **Step 0.2** — Scaffold the repo using `adk_live` template, rename everything to `ayma`
- [x] **Step 0.3** — Run the scaffold locally, understand the folder structure, what each file does

---

### PHASE 1 — Data Layer (Supabase) ✅

- [x] **Step 1.1** — Create Supabase project, enable pgvector, understand what RLS is and why we need it
- [x] **Step 1.2** — Write and run migration: `user_profiles` table with 3-tier profile columns
- [x] **Step 1.3** — Write and run migration: `messages`, `matches` tables + pgvector column
- [x] **Step 1.4** — Write and run migration: `user_skills`, `user_tokens`, `rate_limits`, `llm_usage_log`
- [x] **Step 1.5** — Write and run migration: `profile_suggestions`, `profile_exclusions`
- [x] **Step 1.6** — Create `user_profile_safe` VIEW (this is how we block `ai_observations` from ever reaching the client)
- [x] **Step 1.7** — Write all RLS policies, test them — understand what would break without them
- [ ] **Step 1.8** — Wire Supabase Auth into the backend (replace/wrap the scaffold's default auth)

---

### PHASE 2 — Personalized Agent (LangGraph)

- [x] **Step 2.1** — Understand LangGraph: nodes, edges, state, checkpointer — draw the graph on paper first
- [x] **Step 2.2** — Define `AgentState` (the data that flows through the graph)
- [x] **Step 2.3** — Build the `retrieve` node — fetches Mem0 facts + pgvector RAG in parallel
- [x] **Step 2.4** — Build the `personality` node — assembles the system prompt from profile tiers
- [x] **Step 2.5** — Build the `respond` node — calls Gemini Flash, streams response to client
- [x] **Step 2.6** — Build the `memorize` node — async post-turn: Mem0 write + pgvector embed
- [x] **Step 2.7** — Wire up the full graph: retrieve → personality → respond → memorize
- [x] **Step 2.8** — Add exclusion detection in the `respond` node ("don't mention my job")
- [x] **Step 2.9** — Add Cloud Tasks enqueue in `memorize` node for profile tier updates
- [x] **Step 2.10** — Build the `/internal/update-profile` Cloud Tasks handler (3-tier rewrite with Flash)
- [x] **Step 2.11** — Add BYOT key management (encrypt/store/retrieve, Fernet)

---

### PHASE 3 — Voice (ADK Streaming + Gemini Live)

- [x] **Step 3.1** — Understand the difference between text WebSocket and ADK Streaming voice channel
- [x] **Step 3.2** — Swap the scaffold's default system prompt for Ayma's personalized personality output
- [x] **Step 3.3** — Wire Mem0 context into the Gemini Live session instructions
- [x] **Step 3.4** — Inject the voice modifier (1–3 sentence rule, no markdown)
- [x] **Step 3.5** — Add voice preference setting (Charon / Puck / Kore) stored in `user_profiles`

---

### PHASE 4 — Profile UI (React)

- [x] **Step 4.1** — Profile page: display AI-written public profile (read-only by default)
- [ ] **Step 4.2** — Overwrite button → sets `profile_public_locked = true`, AI switches to suggestion mode
- [ ] **Step 4.3** — `ProfileSuggestions` component — accept / dismiss AI nudges
- [ ] **Step 4.4** — Settings → "What's hidden from your public profile" (view + delete exclusions)
- [ ] **Step 4.5** — "Let AI manage this again" → resets `profile_public_locked = false`

---

### PHASE 5 — Matching Engine

- [ ] **Step 5.1** — Understand the two-stage design: why Stage 1 costs $0 and Stage 2 uses Flash
- [ ] **Step 5.2** — Build Stage 1: dynamic SQL filter + pgvector soft-rank → top 50 candidates
- [ ] **Step 5.3** — Build Stage 2: Flash scoring loop (50 candidates → top 10, structured JSON output)
- [ ] **Step 5.4** — Wrap Stage 1 + Stage 2 in Cloud Tasks jobs (scheduled + event-triggered)
- [ ] **Step 5.5** — React: `Matches` page with `MatchCard` (score, rationale, trigger button)
- [ ] **Step 5.6** — React: `AgentConsentModal` — preview what will be shared before Stage 3

---

### PHASE 6 — Agent-to-Agent (Stage 3)

- [ ] **Step 6.1** — Study the `adk_a2a` starter template — understand the A2A protocol
- [ ] **Step 6.2** — Build the Stage 3 agent prompts (public profile only, no leakage)
- [ ] **Step 6.3** — Build the summarizer — writes `summary_a` + `summary_b` separately to `matches`
- [ ] **Step 6.4** — Supabase Realtime → push notification to React when agent convo completes
- [ ] **Step 6.5** — End-to-end test: two test users, trigger Stage 3, verify no private data in transcript

---

### PHASE 7 — Polish

- [ ] **Step 7.1** — Skill loader: load prompt/tool/MCP skills from `user_skills` table at session start
- [ ] **Step 7.2** — Rate limiting: Supabase counter table, checked at agent entry point
- [ ] **Step 7.3** — Cost guardrails: token budget per task, off-peak scheduling via Cloud Tasks `schedule_time`
- [ ] **Step 7.4** — CLI: thin Python + rich WebSocket wrapper, same backend endpoint
- [ ] **Step 7.5** — Observability: verify Google Cloud Trace is capturing per-turn spans

---

## Decisions and Alternatives (Reference)

| Decision | What we chose | Alternative considered | Why we chose ours |
|----------|--------------|----------------------|-------------------|
| Voice infra | ADK Streaming + Gemini Live | LiveKit + Deepgram + separate TTS | One service vs three; Google manages VAD, turn detection, interruption |
| Background jobs | Cloud Tasks | Celery + Redis | No always-on worker/broker; fits Agent Engine's HTTP model |
| Graph database | Graphiti + Kuzu (embedded) | Neo4j | Zero extra infra; migrate to Neo4j at scale if needed |
| Memory facts | Mem0 v1.0.6 | Agent Engine Memory Bank alone | Mem0 gives structured facts; Memory Bank gives long-term recall; they complement each other |
| LLM default | Gemini 2.5 Flash | GPT-4o, Claude | Flash is fastest + cheapest; Google-native with Agent Engine; Pro available as optional upgrade |
| Auth | Backend-managed Supabase Auth + JWT | Client-owned Supabase SDK, Firebase Auth, Auth0 | Keeps clients thin, centralizes auth/session policy, still uses Supabase as the identity provider |
| Rate limiting | Supabase counter table | Redis, Upstash | Already have Supabase; Redis dropped intentionally |
| Frontend deploy | Vercel | Cloud Run, Netlify | Free tier; zero config for React |
| BYOT encryption | Fernet (AES-256) | AWS KMS, manual AES | Simple, server-side only, no external key service needed at this scale |

---

## Costs at MVP Scale

| Service | Cost |
|---------|------|
| Vertex AI Agent Engine | $0 (Express Mode, 90 days) |
| Supabase | $0 (free tier) |
| Cloud Tasks | $0 (1M tasks/mo free) |
| Gemini Flash | ~$0–5/mo at low traffic |
| Vercel | $0 |
| Mem0 Cloud | $0 (500 ops/mo free) |
| **Total** | **~$0–5/mo** |

---

## Current Step

**-> Step 1.8 — Wire Supabase Auth into the backend**

Thin-client auth is the active architecture rule. Do not add new direct database or auth logic to the clients.
