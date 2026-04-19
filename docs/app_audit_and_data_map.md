# Ayma App Audit And Data Map

Audit date: 2026-04-18

This document is a codebase audit of the current Ayma app. It focuses on:

- what features exist in the app
- which ones appear fully wired end to end
- which ones are partial, placeholder, or not yet operational
- what user data is stored
- where it is stored
- which AI components read or write that data

This is based on the current repository state in `master` plus direct code inspection. It is not a promise that every feature has been runtime-tested on a device in its latest form.

## Current Assessment

Ayma currently has a real backend, real auth, real profile storage, a real live voice path, a real text fallback path, and a real "wiki" memory system. The strongest implemented areas are:

- auth and deep-link email confirmation
- onboarding and profile persistence
- live voice chat using Gemini Live
- text chat fallback using Gemini text generation
- memory writing to both Supabase `messages` and Mem0
- wiki generation and display through "Your Story"
- photo upload, captioning, embedding, and wiki/media indexing

The weakest or incomplete areas are:

- manage memory and exclusions UI
- profile suggestions review UI
- BYOT token management UI and API

## Feature Status

### Likely Wired End To End

These have both frontend and backend code paths, and the storage/inference paths exist.

#### Auth

- Flutter auth screen exists at `/auth`
- Backend routes exist:
  - `/api/auth/login`
  - `/api/auth/signup`
  - `/api/auth/refresh`
  - `/api/auth/session`
  - `/api/auth/logout`
- Deep link confirmation is wired through:
  - Android intent filter in `AndroidManifest.xml`
  - `app_links` in Flutter `main.dart`
  - `AuthService.handleConfirmationLink(...)`
- Auth storage is local in Flutter via `SharedPreferences`

Status: wired

#### Onboarding

- Flutter onboarding screen exists
- Uses `/api/location/search` and `/api/location/reverse`
- Saves through `/api/onboarding`
- Reads completion state through `/api/onboarding-status`
- Persists into `user_profiles`

Status: wired

#### Profile Read And Edit

- Flutter profile screen exists
- Reads via `/api/profile`
- Writes via `/api/profile`
- Safe view `user_profile_safe` is used to prevent exposing `profile_ai_observations`

Status: wired

#### Live Voice Chat

- Flutter chat screen uses `AymaAudioService`
- Backend websocket route `/ws` exists
- Backend bridge is `app/live_bridge.py`
- Bridge uses Gemini Live directly through `google.genai`
- Live session instruction is built from:
  - `user_profiles`
  - Mem0 facts
  - wiki pages
  - user skills
- Tools available in live mode:
  - Google Search
  - `get_current_time`
  - `submit_feedback`

Status: mostly wired. Live turns now also schedule the same post-turn memory/profile/wiki updates as the graph path, so voice conversations contribute to long-term memory. Session stability should still be treated as an active hardening area rather than fully closed.

#### Text Chat Fallback

- Flutter always allows text send
- If live is disconnected, text falls back to `/api/chat/text`
- Backend text path uses the same `_build_instruction(...)` context as live mode
- Attachments can be included in the text path

Status: wired

#### Your Story / Wiki

- Backend:
  - `/api/insights`
  - `app/wiki.py`
  - `app/internal/wiki_update.py`
- Frontend:
  - profile preview card
  - `/insights` screen
- Wiki pages:
  - `about_me.md`
  - `preferences.md`
  - `context.md`
  - `media.md`
- Storage is either:
  - GCS bucket via `WIKI_BUCKET_NAME`
  - local fallback under `.wiki/`

Status: wired

#### Photo Upload And Photo Memory

- Flutter can upload media from profile and chat
- Backend route `/api/media/upload`
- Images are processed inline or via `/internal/process-photo`
- `app/internal/media_process.py` does:
  - caption generation
  - embedding generation
  - insert into `user_media`
  - append to `media.md`

Status: wired for images

### Implemented But Partial

#### Matches Screen

- Flutter matches screen exists
- Backend `/api/matches` exists
- Supabase `matches` table exists
- Backend match generation now exists in `app/internal/match_generation.py`
- Match generation is triggered server-side from onboarding save, profile save, and background profile updates
- Matching is two-stage:
  - Stage 1: structured filtering and heuristic ranking from `user_profiles` + `matching_prefs`
  - Stage 2: Gemini evaluates the shortlisted candidates more deeply and writes/upserts rows to `matches`

Current limits:

- stage 1 is preference-driven and heuristic, not vector-ranked
- `user_media` photo embeddings are not yet used in the active matching pipeline
- quality still needs runtime tuning as real user data accumulates

Status: wired backend generation path, but still needs tuning and production validation

#### Video Upload

- `/api/media/upload` accepts `.mp4` and `.mov`
- chat UI allows upload
- videos are stored
- videos now also go through backend media processing
- processed videos are captioned and appended into `media.md`

Current limits:

- video embeddings are not part of the active matching pipeline
- `user_media` still remains more image-centric than fully general-purpose media retrieval

Status: backend processing exists, but retrieval/matching use is still partial

#### Profile Exclusions

- Exclusion detection exists in `app/graph/nodes/respond.py`
- It writes to `profile_exclusions`
- `profile_update.py` reads `profile_exclusions`

But:

- there is no frontend for viewing or managing exclusions
- live/text bridge paths do not obviously run the same graph node flow as legacy `respond.py`

Status: partially implemented, not clearly surfaced

#### Profile Suggestions

- `profile_suggestions` table exists
- `profile_update.py` writes suggestions when `profile_public_locked = true`
- backend APIs now exist to list and accept/dismiss suggestions
- creating a suggestion also creates a notification

Current limits:

- there is still no dedicated Flutter review UI

Status: backend-complete, UI still partial

### Implemented But Still UI-Partial

#### Notifications

- backend notifications table now exists via migration
- backend routes now exist:
  - `/api/notifications`
  - `/api/notifications/{id}/read`
  - `/api/notifications/read-all`
- existing Flutter notifications provider now loads from the backend instead of in-memory-only state
- new match creation and profile suggestion creation both emit notifications

Status: wired backend and provider

#### Pause Matching

- backend `matching_paused` flag now exists on `user_profiles`
- backend route `/api/settings/pause-matching` now exists
- match generation excludes paused users from candidate generation

Current limits:

- no dedicated UI is wired to the backend toggle yet

Status: backend-complete, UI partial

#### Delete Account

- backend route `/api/account` now exists
- route deletes the Supabase auth user through the admin API
- dependent data cascades through foreign keys
- local/GCS wiki and media cleanup is attempted best-effort

Status: backend-complete, UI partial

#### Settings Actions

These are visible in UI but not yet fully connected to the backend behavior that now exists:

- Manage memory
- Exclusions screen
- Pause matching switch
- Delete account

Status: UI placeholder over partially or fully implemented backend routes

#### BYOT

- Backend helper `app/byot.py` exists
- table `user_tokens` exists

But:

- no app UI
- no exposed API routes for users to manage keys

Status: backend utility only

#### Rate Limits And Usage Logs

- DB tables exist:
  - `rate_limits`
  - `llm_usage_log`

But:

- no obvious active enforcement path
- no UI
- no reporting endpoints

Status: schema only

#### Screen Sharing

- There is no real screen-share transport or live screen-share feature in the current app
- Media upload is not the same as live screen share

Status: not implemented

## User Data Inventory

This section lists the user data that is stored and how it is used.

### Supabase Auth

Source:

- Supabase Auth `auth.users`

Stored data:

- user id
- email
- auth metadata
- session tokens handled by Supabase Auth

Used by:

- login/signup/refresh/session/logout routes
- Flutter auth bootstrap
- ownership checks for profile, media, and matches

### Flutter Local Storage

Source:

- `AuthStorage`

Stored data:

- access token
- refresh token
- expiry
- current user session metadata

Used by:

- auto-login
- token refresh
- websocket auth

Storage medium:

- local device `SharedPreferences`

### Supabase `user_profiles`

Purpose:

- primary structured user profile store

Stored data:

- `id`
- `display_name`
- `profile_public`
- `profile_private`
- `profile_ai_observations`
- `profile_embedding`
- `profile_public_locked`
- `agent_name`
- `voice_preference`
- `matching_prefs`
- `age`
- `gender`
- `religion`
- `location_region`
- `community_profile`
- `onboarding_complete`
- timestamps

Used by:

- onboarding
- profile screen
- live instruction building
- text instruction building
- future matching
- voice selection

Important privacy note:

- `profile_ai_observations` should never be exposed to the client
- frontend reads through `user_profile_safe` view instead

### Supabase `messages`

Purpose:

- long-term conversation turn storage
- semantic memory / history retrieval

Stored data:

- `user_id`
- `role`
- `content`
- `embedding`
- `session_id`
- `created_at`

Written by:

- `app/internal/memory_write.py`

Read by:

- `app/graph/nodes/retrieve.py` for recent message context
- SQL RPC `match_messages(...)`

Note:

- current retrieval logic prefers recent messages and wiki over old semantic RAG
- the table still exists and is actively written

### Mem0 External Memory

Purpose:

- extracted atomic facts

Stored data:

- fact-style memories extracted from user/assistant turns

Written by:

- `app/internal/memory_write.py`

Read by:

- `_build_instruction(...)` in `app/agent.py`
- `app/graph/nodes/retrieve.py`
- `app/internal/profile_update.py`

Characteristics:

- not in Supabase
- stored in Mem0 service
- used as concise structured memory

### Wiki Storage

Purpose:

- synthesized user narrative memory

Pages:

- `about_me.md`
- `preferences.md`
- `context.md`
- `media.md`

Storage backend:

- GCS bucket if `WIKI_BUCKET_NAME` is set
- otherwise local filesystem under `.wiki/`

Written by:

- `app/internal/wiki_update.py`
- live post-turn updates from `app/live_bridge.py` via `run_post_turn_updates(...)`
- `app/internal/media_process.py` for `media.md`

Read by:

- `_build_instruction(...)` in `app/agent.py`
- `retrieve.py`
- `/api/insights`

### Supabase `user_media`

Purpose:

- media memory and future cross-modal matching

Stored data:

- `user_id`
- `photo_url`
- `caption`
- `embedding`
- `media_type`
- `uploaded_at`

Written by:

- `app/internal/media_process.py`

Read by:

- not actively used in the app flow yet
- SQL function `match_user_photos(...)` exists for future matching use

### Media File Storage

Purpose:

- raw uploaded images and videos

Storage backend:

- GCS bucket via `MEDIA_BUCKET_NAME` or `WIKI_BUCKET_NAME`
- otherwise local filesystem under `.media/`

Routes:

- `/api/media/upload`

Used by:

- text multimodal chat attachments
- image processing pipeline
- future matching/media flows

### Supabase `matches`

Purpose:

- server-generated match results and agent-to-agent summaries

Stored data:

- user pair ids
- score
- commonalities
- differences
- rationale
- `summary_a`
- `summary_b`
- `convo_transcript`
- status

Current reality:

- schema and read API exist
- app reads it
- backend generation path now exists in `app/internal/match_generation.py`

### Supabase `profile_exclusions`

Purpose:

- topics user wants excluded from public profile

Stored data:

- `user_id`
- `topic`
- `tier`

Written by:

- exclusion detection in `respond.py`

Read by:

- `app/internal/profile_update.py`

### Supabase `profile_suggestions`

Purpose:

- AI-generated public profile drafts when user locks public profile

Stored data:

- `user_id`
- `tier`
- `draft`
- `status`
- `created_at`

Written by:

- `app/internal/profile_update.py`

Read by:

- `/api/profile/suggestions`
- `/api/profile/suggestions/{id}` accept/dismiss action

### Supabase `user_skills`

Purpose:

- user-specific prompt/tool/MCP style instructions

Stored data:

- `name`
- `skill_type`
- `content`
- `enabled`

Written by:

- agent helper functions in `app/agent.py`

Read by:

- `load_user_skills(...)`
- injected into system instruction for live/text paths

### Supabase `app_feedback`

Purpose:

- app bug reports, feature requests, UX issues

Stored data:

- `user_id`
- `feedback`
- `category`
- `context`
- `reviewed`

Written by:

- `submit_feedback` tool in `app/agent.py`

Read by:

- no product UI found

### Supabase `user_tokens`

Purpose:

- encrypted bring-your-own-provider tokens

Stored data:

- `provider`
- encrypted API key
- label

Written by:

- `app/byot.py`

Read by:

- `app/byot.py`

Current reality:

- no frontend or public API route currently uses this

### Supabase `rate_limits` And `llm_usage_log`

Purpose:

- future cost control and observability

Current reality:

- schema exists
- active enforcement/reporting not found

## AI Components And What They Work On

### 1. Live Voice Agent

Code:

- `app/live_bridge.py`
- instruction builder in `app/agent.py`

Reads:

- `user_profiles`
- Mem0 facts
- wiki pages
- `user_skills`

Writes:

- can write `app_feedback` through tool call
- on turn completion, now schedules the same post-turn memory pipeline used by the graph path
- therefore indirectly writes `messages`, Mem0 facts, profile updates, and wiki pages

Role:

- realtime Gemini Live voice interaction

### 2. Text Fallback Agent

Code:

- `/api/chat/text` in `app/app_utils/expose_app.py`

Reads:

- same `_build_instruction(...)` context as live
- optional uploaded media bytes
- text history from client

Writes:

- no direct DB write in route itself
- user/assistant exchange later enters memory pipeline only if another flow stores it

Role:

- non-live text and attachment chat fallback

### 3. Memory Writer

Code:

- `app/internal/memory_write.py`

Reads:

- recent exchange messages

Writes:

- Supabase `messages`
- Mem0 facts

Role:

- persistent long-term memory ingestion

### 4. Profile Updater

Code:

- `app/internal/profile_update.py`

Reads:

- Mem0 facts
- `user_profiles`
- `profile_exclusions`

Writes:

- `user_profiles.profile_public`
- `user_profiles.profile_private`
- `user_profiles.profile_ai_observations`
- `profile_suggestions` when public profile is locked

Role:

- continuously rewrite user profile layers

### 5. Wiki Updater

Code:

- `app/internal/wiki_update.py`

Reads:

- last exchange
- current wiki pages

Writes:

- wiki pages in GCS or `.wiki/`

Role:

- maintain narrative memory pages

### 6. Media Processor

Code:

- `app/internal/media_process.py`

Reads:

- uploaded image or video bytes

Writes:

- `user_media`
- wiki `media.md`

Role:

- turn user media into reusable AI memory and future matching features

### 7. Match Generator

Code:

- `app/internal/match_generation.py`

Reads:

- `user_profiles`
- `matching_prefs`
- wiki pages
- optional photo-similarity boosts from `user_media` via `match_user_photos(...)`

Writes:

- `matches`
- notifications for new matches

Role:

- server-side two-stage matching pipeline

## Database And Storage Map

### Supabase Auth

- authentication
- sessions
- user identity

### Supabase Postgres

Used for:

- profiles
- messages
- matches
- notifications
- skills
- profile exclusions
- profile suggestions
- onboarding state
- app feedback
- user media metadata
- BYOT metadata
- future rate limiting and usage logs

### Mem0

Used for:

- extracted atomic user facts

### GCS Or Local Filesystem

Used for:

- wiki pages
- uploaded media files
- optional telemetry/log buckets

### Flutter Local Device Storage

Used for:

- auth session persistence

## What Is Missing Or Should Be Next

This is the practical backlog based on what the repo already has.

### High Priority

1. Finish live session hardening.
   The first-turn failure was fixed, but session longevity and reconnect behavior should be verified on-device repeatedly.

2. Build profile suggestion review UI.
   Backend routes exist, but users still need a proper review surface.

3. Build exclusions and memory management UI.
   Backend support exists, but the settings actions are still placeholders.

4. Tune and validate the new matching pipeline.
   The server-side two-stage matcher now exists, but the scoring heuristics and Gemini prompts need production tuning.

5. Connect the pause-matching and delete-account UI controls to the backend routes that now exist.

### Medium Priority

6. Improve video understanding beyond captioning.
   Videos are now processed into captions and wiki memory, but not yet used in matching.

7. Expose BYOT if it is part of the product plan.

8. Deepen media-aware matching by using `user_media` and `match_user_photos(...)` more aggressively in scoring.

9. Add rate limiting and job observability on top of the newly expanded backend workflows.

## Honest Confidence Summary

### Strong Confidence

- auth
- onboarding
- profile read/write
- insights/wiki display
- photo upload path for images
- text fallback path

### Medium Confidence

- live voice path
- live post-turn memory/profile/wiki updates
- image processing and wiki/media persistence

These are implemented, but they need repeated runtime verification rather than just code confidence.

### Low Confidence Or Incomplete

- settings actions
- advanced video intelligence
- BYOT user flow
