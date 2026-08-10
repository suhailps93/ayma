# Ayma System Architecture

> **Last updated:** 2026-07-21  
> **Canonical architecture doc.** Read this first for a full picture of how the system works today.
> Execution checklist and handoffs live in [`PLAN.md`](../PLAN.md). Ops commands live in [`agent.md`](agent.md).

---

## What Ayma Is

Ayma is a serverless AI matchmaking platform. Users talk to a personalized AI companion (LiveKit voice with Gemini Live, or text chat). Each conversation enriches a structured profile wiki and questionnaire answers in Google Cloud Firestore. A matching engine finds compatible people using hard filters, heuristic ranking, LLM scoring, and optional agent-to-agent vibe checks.

**Design principle:** the Flutter client is thin. It handles presentation, device I/O (mic, camera, playback), Firebase Auth, and authenticated HTTP/WebSocket calls. All business logic — profile CRUD, memory extraction, matching, messaging — lives in the Cloud Run backend.

---

## High-Level Diagram

```mermaid
flowchart TB
  subgraph Client["Flutter App (ayma_flutter)"]
    UI[Screens + Riverpod]
    ApiSvc[ApiService — data CRUD]
    BackendSvc[BackendService — AI ops]
    AudioSvc[AudioService — LiveKit WebRTC voice/text]
    Storage[Firebase Storage SDK — photos]
    Auth[Firebase Auth SDK]
  end

  subgraph GCP["Google Cloud"]
    CR[Cloud Run: ayma-bootstrap<br/>FastAPI + Firestore Client + LiveKit Agent]
    Scheduler[Cloud Scheduler<br/>daily matching cron]
  end

  subgraph Firebase["Firebase (ayma-ai)"]
    FAuth[Auth — identity & JWT verification]
    FStore[Storage — media files]
    FSDB[(Firestore Database<br/>users, matches, conversations, subcollections)]
  end

  subgraph LiveKit["LiveKit Cloud"]
    LKR[LiveKit Room / WebRTC]
  end

  subgraph Gemini["Gemini API"]
    Live[Live API<br/>gemini-3.1-flash-live-preview]
    Text[Text REST<br/>gemini-3.5-flash]
  end

  UI --> ApiSvc & BackendSvc & AudioSvc
  Auth --> FAuth
  Storage --> FStore
  ApiSvc -->|Bearer JWT| CR
  BackendSvc -->|Bearer JWT| CR
  AudioSvc -->|POST /bootstrap token| CR
  AudioSvc -->|WebRTC Audio/Data| LKR
  CR -->|LiveKit Agent Worker| LKR
  LKR -->|Gemini Realtime Multimodal| Live
  CR --> FSDB
  CR --> Text
  Scheduler -->|POST /run-matching-cron| CR
  CR -->|verify token| FAuth
```

---

## Stack Summary

| Layer | Technology | Role |
|---|---|---|
| Mobile client | Flutter + Riverpod + go_router | UI, routing, state |
| Identity | Firebase Auth | Email/password sign-in; JWT for backend |
| Media files | Firebase Storage | Photo uploads (direct from client) |
| Application data | Google Cloud Firestore | Profiles, wiki, matches, conversations, notifications |
| Backend | FastAPI on Cloud Run | All REST endpoints + LiveKit Agent worker |
| Voice AI | LiveKit Cloud + Gemini Live | Real-time WebRTC audio streaming with AEC & barge-in |
| Text AI | Gemini REST (`gemini-3.5-flash`) | Post-turn extraction, text chat, matching, vibe check |
| Scheduled jobs | Cloud Scheduler | Daily batch matching |

---

## Database

Google Cloud Firestore (`google-cloud-firestore`) stores all application data. The backend connects asynchronously via `AsyncClient` in FastAPI app state (`app.state.db`).

Top-level collections:
- `users/{uid}`: Profile fields, wiki maps, settings, matching preferences.
- `matches/{pairId}`: Match metadata, scores, synergy, and status.
- `conversations/{pairId}/messages`: Direct chat messages between matched users.

Subcollections under `users/{uid}`:
- `user_media`: Photo metadata records.
- `user_memories`: Audio turn transcript audit log.
- `user_questions`: Pending and answered questionnaire checklist.
- `user_skills`: Custom AI skill instructions.
- `notifications`: In-app notification inbox.

---

## Repository Layout (complete)

Every source file in the repo and what it does. Excludes build outputs (`.dart_tool/`, `build/`), virtualenvs (`.venv/`), and git internals.

---

### Repo root

| File | Purpose |
|---|---|
| `PLAN.md` | Canonical cross-agent execution checklist, validation log, and handoffs |
| `README.md` | Repo overview and quick commands (points to PLAN + ARCHITECTURE) |
| `CLAUDE.md` | Claude/Codex agent entrypoint: quick commands and coding rules |
| `schema.sql` | Legacy PostgreSQL DDL (retained for reference; app data is in Firestore) |
| `firebase.json` | Firebase deploy config (Storage rules + `functions/triggers`) |
| `storage.rules` | Firebase Storage security rules for photo uploads |
| `.gitignore` | Git ignore patterns |

---

### `docs/` — documentation

| File | Purpose |
|---|---|
| `ARCHITECTURE.md` | **This file** — full system architecture |
| `agent.md` | Ops guide: deploy, ADB, env vars, local backend |
| `manual_testing_guide.md` | End-to-end local testing runbook |
| `ui_test_plan.md` | Screen-by-screen UI/runtime test matrix |
| `cloud-scheduler.md` | Daily matching cron setup for Cloud Scheduler |

---

### `functions/triggers/` — Firebase Functions

| File | Purpose |
|---|---|
| `main.py` | `cleanup_deleted_user` Firestore trigger — cascade-deletes user subcollections, matches, and conversations when `users/{uid}` is deleted |
| `requirements.txt` | Python dependencies for the trigger function |

---

### `functions/bootstrap/` — Cloud Run backend

| File | Purpose |
|---|---|
| `main.py` | FastAPI app — all REST endpoints, auth, matching, post-turn |
| `config.py` | Tuneable constants: models, thresholds, rate limits, pool sizes |
| `questionnaire_graph.py` | Matching filters, heuristic weights, LLM prompts, schema loaders |
| `questionnaire_schema.json` | Question field catalog + community configs (loaded by questionnaire_graph) |
| `requirements.txt` | Python dependencies for Cloud Run container |
| `Dockerfile` | Container build: copies main.py, config, questionnaire_graph |
| `test_main_logic.py` | Backend unit tests (community drift guard, bootstrap, post-turn) |
| `pipeline_test.py` | End-to-end pipeline smoke script |
| `skills-lock.json` | Agent skill lockfile (MCP/browser tooling metadata) |

---

### `tests/` — Python tests

| File | Purpose |
|---|---|
| `unit/test_matching.py` | Unit tests for matching and vibe-check logic |

---

### `ayma_flutter/` — Flutter mobile app

#### Project config

| File | Purpose |
|---|---|
| `pubspec.yaml` | Flutter dependencies and asset declarations |
| `pubspec.lock` | Locked dependency versions |
| `analysis_options.yaml` | Dart linter rules |
| `devtools_options.yaml` | Flutter DevTools settings |
| `firebase.json` | FlutterFire project config |
| `.metadata` | Flutter project metadata (channel, revision) |
| `.gitignore` | Flutter-specific git ignores |
| `README.md` | Flutter project readme |

#### `ayma_flutter/lib/` — application code

| File | Purpose |
|---|---|
| `main.dart` | App entry: Firebase init, Riverpod root, go_router, overlay mini-app |
| `router.dart` | go_router: auth/onboarding guards and shell tab routes |
| `env.dart` | Build-time config: Cloud Run URL, AI provider, API keys |
| `theme.dart` | Design system: colors, typography, Material theme |
| `firebase_options.dart` | Firebase platform keys (generated by `flutterfire configure`) |

**`lib/models/`**

| File | Purpose |
|---|---|
| `profile.dart` | `UserProfile` model — parses `/profile` responses |
| `match_model.dart` | `MatchModel` — score, rationale, synergy, summaries |
| `notification_model.dart` | In-app notification types and model |
| `auth_session.dart` | Thin `AuthUser` wrapper from Firebase Auth |
| `community_profile.dart` | Community configs: question IDs, prompt tone, completeness weights |

**`lib/providers/`**

| File | Purpose |
|---|---|
| `providers.dart` | Riverpod providers: auth, profile, matches, notifications, audio |

**`lib/services/`**

| File | Purpose |
|---|---|
| `api_service.dart` | HTTP client for all backend data CRUD + inline question bank |
| `backend_service.dart` | Cloud Run AI ops: bootstrap, post-turn, matching, vibe-check, Storage |
| `audio_service.dart` | Voice/text chat orchestration, transcript, post-turn trigger |
| `auth_service.dart` | Firebase Auth: email, phone, Google, Apple sign-in |
| `gemini_live_client.dart` | Gemini Live WebSocket: setup, audio, tool calls |
| `openai_realtime_client.dart` | OpenAI Realtime WebSocket (alt provider) |
| `audio_recorder_service.dart` | Mic capture → PCM16 (mobile + web) |
| `audio_streamer_service.dart` | Speaker playback for AI audio chunks |
| `overlay_service.dart` | Android floating overlay for voice while multitasking |
| `web_audio_impl.dart` | Web Audio API implementation (Flutter Web) |
| `web_audio_stub.dart` | No-op audio stubs for iOS/Android native |

**`lib/screens/`**

| File | Purpose |
|---|---|
| `auth/auth_screen.dart` | Sign-in and sign-up flows |
| `onboarding/onboarding_screen.dart` | 5-step onboarding: community, demographics, location, prefs, photos |
| `shell/shell_screen.dart` | Bottom nav shell and overlay hook |
| `chat/chat_screen.dart` | Main AI companion: voice, text, transcript |
| `matches/matches_screen.dart` | Match list and "Find matches" trigger |
| `matches/match_detail_screen.dart` | Match detail: score, vibe check, accept/reject |
| `explore/explore_screen.dart` | Browse people with filters |
| `explore/direct_message_screen.dart` | DM thread with another user |
| `profile/profile_screen.dart` | Profile editor: bio, photos, wiki, completeness |
| `notifications/notifications_screen.dart` | Notification inbox |
| `settings/settings_screen.dart` | Voice, privacy, account settings |

**`lib/widgets/`**

| File | Purpose |
|---|---|
| `ayma_button.dart` | Branded primary/outlined button |
| `ayma_text_field.dart` | Styled text input |
| `public_profile_view.dart` | Public profile card for explore and match detail |

**`lib/utils/`**

| File | Purpose |
|---|---|
| `distance_units.dart` | Locale-aware km vs miles formatting |

#### `ayma_flutter/scripts/` — dev tooling

| File | Purpose |
|---|---|
| `check-flutter-env` | Validates Flutter SDK, ADB, and env readiness |
| `adb-ui` | ADB-based UI inspection fallback (screenshot, tap, dump) |
| `adb-ts` | ADB over Tailscale (wireless device connect) |

#### `ayma_flutter/test/`

| File | Purpose |
|---|---|
| `widget_test.dart` | Default Flutter widget smoke test |

#### `ayma_flutter/assets/fonts/`

| File | Purpose |
|---|---|
| `Geist-*.woff2` | Geist font files (Light, Regular, Medium, SemiBold) |

#### `ayma_flutter/android/` — Android platform

| File | Purpose |
|---|---|
| `build.gradle.kts` | Root Android Gradle config |
| `settings.gradle.kts` | Gradle project settings |
| `gradle.properties` | Gradle JVM and Android properties |
| `gradle/wrapper/gradle-wrapper.properties` | Gradle wrapper version |
| `app/build.gradle.kts` | App module: SDK versions, dependencies, signing |
| `app/google-services.json` | Firebase Android config |
| `app/src/main/AndroidManifest.xml` | App permissions, deep links, overlay intent |
| `app/src/main/kotlin/.../MainActivity.kt` | Android activity entry point |
| `app/src/debug/AndroidManifest.xml` | Debug manifest overrides |
| `app/src/profile/AndroidManifest.xml` | Profile build manifest overrides |
| `app/src/main/res/drawable/launch_background.xml` | Splash screen drawable |
| `app/src/main/res/drawable-v21/launch_background.xml` | Splash screen (API 21+) |
| `app/src/main/res/values/styles.xml` | App theme styles |
| `app/src/main/res/values-night/styles.xml` | Dark mode theme styles |
| `app/src/main/res/mipmap-*/ic_launcher.png` | Launcher icons (hdpi → xxxhdpi) |

#### `ayma_flutter/ios/` — iOS platform

| File | Purpose |
|---|---|
| `Runner/AppDelegate.swift` | iOS app delegate |
| `Runner/Info.plist` | iOS permissions and config |
| `Runner/Runner-Bridging-Header.h` | Obj-C/Swift bridging header |
| `Runner/Base.lproj/Main.storyboard` | Main storyboard |
| `Runner/Base.lproj/LaunchScreen.storyboard` | Launch screen |
| `Runner/Assets.xcassets/AppIcon.appiconset/*` | App icon assets (all sizes) |
| `Runner/Assets.xcassets/LaunchImage.imageset/*` | Launch image assets |
| `Runner.xcodeproj/project.pbxproj` | Xcode project file |
| `Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` | Xcode run scheme |
| `Runner.xcworkspace/contents.xcworkspacedata` | Xcode workspace |
| `Flutter/Debug.xcconfig` | Debug build config |
| `Flutter/Release.xcconfig` | Release build config |
| `Flutter/AppFrameworkInfo.plist` | Flutter framework metadata |
| `RunnerTests/RunnerTests.swift` | iOS unit test stub |

#### `ayma_flutter/web/` — Flutter Web

| File | Purpose |
|---|---|
| `index.html` | Web app shell and Flutter loader |
| `manifest.json` | PWA manifest |
| `favicon.png` | Browser tab icon |
| `icons/Icon-*.png` | PWA icons (192, 512, maskable variants) |

---

## Flutter Client

### Navigation

| Route | Screen | Notes |
|---|---|---|
| `/auth` | AuthScreen | Redirect target when logged out |
| `/onboarding` | OnboardingScreen | Community selection, demographics, location, prefs |
| `/chat` | ChatScreen | Default tab; voice + text AI companion |
| `/matches` | MatchesScreen | List matches; trigger `/run-matching` |
| `/explore` | ExploreScreen | Browse people; filters by age/gender/radius |
| `/profile` | ProfileScreen | Public/private split, photo carousel, completeness |
| `/notifications` | NotificationsScreen | Read + mark-read |
| `/settings` | SettingsScreen | Voice, privacy, account |

Sub-screens (not top-level routes): `MatchDetailScreen`, `DirectMessageScreen`.

Auth guard: unauthenticated → `/auth`. Incomplete onboarding → `/onboarding`.

### Service Boundaries

| Service | Responsibility |
|---|---|
| `ApiService` | Profile, matches, notifications, explore, insights, media records, messages, questions — all via authenticated HTTP to Cloud Run |
| `BackendService` | AI pipeline calls: `/bootstrap`, `/post-turn`, `/run-matching`, `/vibe-check`, `/device-token`; Firebase Storage uploads |
| `AudioService` | LiveKit WebRTC voice/text session, transcript persistence (SharedPreferences), calls `BackendService.postTurn` on turn complete |
| `AuthService` | Firebase Auth sign-in/out, session state |

**Rule:** all backend calls go through `ApiService` or `BackendService` — no direct database access from screens.

### Backend URL

Configured in `ayma_flutter/lib/env.dart`. Default production:

```
https://ayma-bootstrap-235381544962.us-central1.run.app
```

Override at build time: `flutter run --dart-define=AYMA_BOOTSTRAP_URL=https://...`

---

## Cloud Run Backend

Single FastAPI service: `functions/bootstrap/main.py`. All endpoints verify Firebase ID tokens via `Authorization: Bearer <token>` unless noted.

### Endpoint Reference

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Liveness check |
| POST | `/bootstrap` | Build system prompt, return Gemini Live setup + API key |
| POST | `/post-turn` | Extract wiki updates + structured answers from conversation |
| GET/POST | `/profile` | Read/update user profile (upsert on first write) |
| GET | `/profile/{userId}/public` | Public profile view for other users |
| GET | `/insights` | Wiki + media for "Your Story" screen |
| GET/POST | `/profile/answers` | Structured questionnaire answers |
| GET | `/questions/pending` | Unanswered checklist questions |
| POST | `/questions/followup` | Add follow-up question from Live tool call |
| POST | `/questions/{qid}/answered` | Mark question answered |
| GET | `/explore` | Filtered people browse (gender/age/radius + LLM-parsed structured attrs + free-text) |
| POST/DELETE | `/media` | Register/delete media records (files in Firebase Storage) |
| POST | `/profile/analyze-photos` | Gemini photo analysis → profile hints |
| POST | `/device-token` | Store FCM push token |
| POST/GET | `/messages`, `/messages/{other_user_id}` | Direct messaging |
| POST | `/chat` | Text chat via REST (used by Flutter client) |
| POST | `/chat/text` | Server-side text chat (alternative fallback endpoint) |
| GET | `/matches` | List user's matches |
| POST | `/matches/{pair_id}/status` | Accept/reject match |
| POST | `/run-matching` | On-demand matching for current user |
| POST | `/run-matching-cron` | Batch matching for all users (Cloud Scheduler, `X-Cron-Secret`) |
| POST | `/vibe-check` | Agent-to-agent simulation for a match |
| GET | `/matches/{pair_id}/simulation` | Vibe-check transcript |
| POST | `/matches/{pair_id}/toggle-simulation` | Privacy toggle for transcript |

Rate limits configured in `config.py` (slowapi, per IP).

### Configuration (`config.py`)

All tuneable values — models, matching thresholds, pool sizes, cron secret — live in `functions/bootstrap/config.py`. Environment variables override defaults. Do not hardcode these elsewhere.

Key defaults:

| Setting | Default |
|---|---|
| `LIVE_MODEL` | `gemini-3.1-flash-live-preview` |
| `TEXT_MODEL` | `gemini-3.5-flash` |
| `EMBEDDING_MODEL` | `gemini-embedding-2` |
| `MATCH_SCORE_MIN` | `0.4` (0–1 scale) |
| `VIBE_CHECK_THRESHOLD` | `0.65` |
| `MATCH_CANDIDATE_POOL` | `100` |
| `MATCH_SCORE_TOP_K` | `15` |
| `VIBE_CHECK_TOP_K` | `5` |

---

## Core Flows

### 1. Authentication

1. User signs in via Firebase Auth (email/password).
2. Flutter obtains ID token from Firebase.
3. Every backend call sends `Authorization: Bearer <id_token>` and `X-Firebase-AppCheck: <app_check_token>`.
4. Backend verifies Firebase ID token and App Check token (monitor mode by default; set `APP_CHECK_ENFORCE=true` to reject invalid/missing tokens).

Firebase is **identity only**. No profile data in Firebase beyond Auth user record.

Sign-in flow: `AuthScreen` → `AuthService` (email/phone/Google/Apple) → Firebase Auth → `ApiService.getProfile()` bootstraps the Firestore user doc → router redirects to `/chat` or `/onboarding`. Every `ApiService`/`BackendService` call sends `Authorization: Bearer <id_token>`. Backend `verify_token()` uses Firebase Admin SDK. FCM token registered via `POST /device-token` on sign-in.

### 2. Onboarding

1. User selects a **community profile** (e.g. `dating_western`, `arranged_india`, `friends_bff`) — defines question set and prompt style.
2. Flutter POSTs demographics, location, matching prefs to `/profile`.
3. Backend upserts `users/{uid}` in Firestore (`ensure_user_doc` / `update_user_doc`).
4. On first `/bootstrap`, backend seeds `users/{uid}/user_questions` from community-specific question catalog.
5. `onboarding_complete` flag gates explore/matching.

Community profiles are defined in `ayma_flutter/lib/models/community_profile.dart` and must stay in sync with backend `COMMUNITY_CONFIG` in `questionnaire_schema.json` (guarded by `test_main_logic.py`).

Onboarding steps: welcome → community selection → about you (name, gender, age) → preferences (interested_in, age range, location) → photos (optional). Completing sets `onboarding_complete=true` via `POST /profile`. Router caches completion in SharedPreferences to skip re-checking on launch.

### 3. Voice Session (LiveKit + Gemini Live)

```
Flutter                          Cloud Run                    LiveKit Cloud              Gemini Live
   │ POST /bootstrap ──────────────►│                           │                          │
   │◄── LiveKit token + room URL ──│                           │                          │
   │ WebRTC connect ────────────────────────────────────────────►│                          │
   │◄── audio + data channels ───────────────────────────────────│                          │
   │                                                               │ Agent worker ───────────►│
   │                                                               │◄── realtime audio ───────│
   │ on turnComplete: POST /post-turn ─►│ (Firestore wiki update)  │                          │
```

Steps:

1. `AudioService` calls `BackendService.bootstrap()`.
2. Backend reads Firestore profile + wiki fields + pending questions + skills; builds system prompt; returns a LiveKit access token and room URL.
3. `AudioService` connects to LiveKit via WebRTC — audio routes through LiveKit, not Cloud Run.
4. The embedded LiveKit Agent worker (`agent.py`) joins the room, runs Gemini Live for voice, and handles text via data channels.
5. Gemini Live tool: `add_followup_question` → written to `users/{uid}/user_questions`.
6. On turn complete, the agent (or Flutter) sends transcript to `/post-turn` for wiki extraction.

Session states: `disconnected` → `connecting` → `ready` → `listening` ↔ `thinking` ↔ `speaking`. Barge-in commits partial transcript and calls `/post-turn`. Transcript persisted in SharedPreferences per UID.

### 4. Text Chat

Text chat shares the LiveKit room with voice:

- **Primary (Flutter Client):** `AudioService.sendText()` publishes text on the LiveKit data channel. The embedded agent worker (`agent.py`) handles the LLM reply and broadcasts it back on the same channel.
- **REST fallback:** `POST /chat` and `POST /chat/text` rebuild the system prompt from Firestore and run Gemini on Cloud Run (useful for testing without a LiveKit session).

Both voice and text chat trigger the same `/post-turn` memory pipeline when a conversational turn completes.

### 5. Memory & Profile Wiki

After every voice or text turn, `/post-turn` runs one consolidated Gemini call that returns JSON with:

| Output | Stored in |
|---|---|
| Wiki upserts (`about_me`, `context`, `preferences`, `matching`) | `users/{uid}` wiki fields |
| Structured field extractions | `users/{uid}.profile_answers*` maps |
| Answered question keys | `users/{uid}/user_questions` docs |
| Public summary draft | `users/{uid}.profile_public_pending` |
| Verbatim user lines | `users/{uid}.raw_user_statements` (audit) |
| Raw conversation snippet | `users/{uid}/user_memories` subcollection (debug trail) |

At next `/bootstrap`, all four wiki fields are injected into the system prompt (~500 tokens of dense, deduplicated context). No vector search at bootstrap time.

Question routing and hard-filter logic: `questionnaire_graph.py`.  
Field catalog and community configs: `questionnaire_schema.json` (via `load_profile_schema()`).

### 6. Photo Upload

1. Flutter uploads bytes directly to Firebase Storage (`uploads/{uid}/{filename}`).
2. Flutter POSTs download URL to `/media` → doc in `users/{uid}/user_media`.
3. Optional: `/profile/analyze-photos` sends URLs to Gemini for profile hints.

### 7. Matching Pipeline

Two passes, all in Cloud Run:

```
┌─────────────────────────────────────────────────────────────┐
│ PASS 1: Candidate pool                                      │
│   Firestore query for onboarded users                       │
│   → heuristic filter (_is_heuristic_match)                  │
│     age range, gender prefs, intent, dealbreakers           │
└──────────────────────────┬──────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ PASS 2: LLM compatibility scoring (_score_pair)           │
│   PII stripped before Gemini call                           │
│   Returns score (0–1), rationale, per-user summaries       │
│   Top pairs above MATCH_SCORE_MIN written to matches/{pairId}│
└──────────────────────────┬──────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ PASS 3: Vibe check (_run_vibe_check) — optional             │
│   For pairs ≥ VIBE_CHECK_THRESHOLD:                         │
│   4–5 turn agent-to-agent dialogue simulation               │
│   Synergy score blended into final match score              │
│   Transcript stored in matches/{pairId}/simulations         │
└─────────────────────────────────────────────────────────────┘
```

Triggers:

| Trigger | Endpoint | Notes |
|---|---|---|
| User taps "Find matches" | `POST /run-matching` | Full pipeline incl. auto vibe-check for top pairs |
| Daily cron | `POST /run-matching-cron` | Lighter pool; no vibe-check; see `cloud-scheduler.md` |
| User requests vibe check | `POST /vibe-check` | Re-run simulation for existing match |

### 8. Direct Messaging

- `POST /messages` — send DM to another user.
- `GET /messages/{other_user_id}` — fetch thread.
- FCM push notification sent to recipient (token stored via `/device-token`).

Explore screen → public profile → DirectMessageScreen.

---

## Legacy PostgreSQL Schema

> **Note:** The app no longer uses PostgreSQL at runtime. All data lives in Firestore (see Database section above). `schema.sql` is retained only as a historical reference for the original table layout.

Key concepts that map to Firestore:

| Old SQL table | Firestore location |
|---|---|
| `users` | `users/{uid}` |
| `user_skills` | `users/{uid}/user_skills` |
| `user_questions` | `users/{uid}/user_questions` |
| `user_memories` | `users/{uid}/user_memories` |
| `user_media` | `users/{uid}/user_media` |
| `notifications` | `users/{uid}/notifications` |
| `matches` | `matches/{pairId}` (deterministic ID from sorted UIDs) |
| `match_simulations` | `matches/{pairId}/simulations` |
| `messages` (DMs) | `conversations/{pairId}/messages` |

---

## Firebase (Auth + Storage)

| Service | Role |
|---|---|
| Firebase Auth | Sign-in, ID tokens for backend auth |
| Firebase Storage | Photo file blobs (`uploads/{uid}/{filename}`) |

Bucket: `ayma-ai.firebasestorage.app`.

---

## Deployed Infrastructure

| Resource | Value |
|---|---|
| GCP project | `ayma-ai` |
| Cloud Run service | `ayma-bootstrap` |
| Cloud Run URL | `https://ayma-bootstrap-235381544962.us-central1.run.app` |
| Cloud Run SA | `vertex-express@ayma-ai.iam.gserviceaccount.com` |
| Firestore | Native mode, project `ayma-ai` |
| Firebase Storage | `ayma-ai.firebasestorage.app` |
| Firebase Functions | `functions/triggers` — user deletion cascade |

Local dev: set `GOOGLE_API_KEY` and Firebase credentials, then `uvicorn main:app --port 8080` from `functions/bootstrap/`.

---

## Privacy Rules

1. **Bootstrap prompt** includes real name, age, gender, location for the conversational companion — intentional for personalization.
2. **Matching LLM calls strip PII** — name, exact location, employer removed before scoring (`strip_pii()` in main.py).
3. **Private notes** (`profile_private`, sensitive answers) never sent to matching or vibe-check prompts.
4. **Vibe-check simulation** uses public profile fields only.
5. **API key returned to authenticated clients** — acceptable for internal app; migrate to Vertex short-lived tokens before public release.

---

## Community Profiles

Six community configurations in `CommunityProfiles.all`:

- `dating_western`, `arranged_india`, `matrimonial_muslim`, `arranged_africa_west`, `dating_lgbtq`, `friends_bff`, `career_network`

Each defines:

- Question subset and ordering
- Prompt tone/style for `/bootstrap` system prompt
- Completeness scoring weights in Flutter

Stored as `users/{uid}.community_profile`. Backend reads it to select active questions and prompt behavior.

---

## Validation Commands

```bash
# Backend unit tests
python3 -m unittest functions/bootstrap/test_main_logic.py

# Backend syntax
python3 -m py_compile functions/bootstrap/main.py

# Flutter static analysis
cd ayma_flutter && flutter analyze

# Flutter env check
./ayma_flutter/scripts/check-flutter-env

# Local backend
export GOOGLE_API_KEY="your-key"
cd functions/bootstrap && uvicorn main:app --host 0.0.0.0 --port 8080
```

Runtime testing: see [`manual_testing_guide.md`](manual_testing_guide.md) and [`ui_test_plan.md`](ui_test_plan.md).

---

## Related Docs

| Doc | Purpose |
|---|---|
| [`PLAN.md`](../PLAN.md) | Cross-agent checklist, handoffs, blockers |
| [`agent.md`](agent.md) | Deploy commands, ADB device setup, env vars |
| [`manual_testing_guide.md`](manual_testing_guide.md) | End-to-end local testing |
| [`ui_test_plan.md`](ui_test_plan.md) | Screen-by-screen test matrix |
| [`cloud-scheduler.md`](cloud-scheduler.md) | Daily matching cron setup |

---

## Current Gaps & Next Work

From `PLAN.md` — not yet fully validated:

- [ ] Deploy Firestore-backed backend to Cloud Run and smoke-test all endpoints (including `/explore` structured + free-text search)
- [ ] Deploy `functions/triggers` Firebase codebase
- [ ] Single source of truth for question definitions across Flutter + backend (currently duplicated with drift guard in tests)
- [ ] Legacy users with `dating_standard` community profile migration
- [ ] Text chat integration test (ADB cannot type into Flutter TextFields)
- [ ] Voice chat smoke test on physical device
- [ ] Multi-user matching end-to-end test (seed 2+ users, verify match creation)
- [ ] Profile completeness progression UX (chat → wiki updates → % increases visibly)
