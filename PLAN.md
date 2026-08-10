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
- **All application data now lives in Firestore** (`google-cloud-firestore` AsyncClient in `app.state.db`). PostgreSQL/Cloud SQL is retired from runtime (instance stopped; code no longer requires `DATABASE_URL`).
- Community-specific onboarding and question selection are implemented on this branch.
- Voice uses LiveKit + embedded `agent.py` worker; text chat uses Cloud Run REST + LiveKit data channels.
- Some older docs (e.g. `docs/database-user-data.md`, PHASE 1 checklist below) still describe Postgres — treat as legacy unless reconciled here.

### Current production-readiness priorities

- [x] Deploy Firestore-backed backend to Cloud Run (`ayma-bootstrap`, scale-to-zero) — verified live `/health` -> {"status":"ok"}
- [ ] Deploy `functions/triggers` Firebase codebase (user-deletion cascade + future cron)
- [ ] Stabilize community-profile onboarding end-to-end against deployed Firestore backend
- [x] Reconcile stale architecture/testing docs with the actual branch state
- [x] Re-establish repeatable validation commands for backend and Flutter analysis
- [ ] Run emulator/device smoke coverage after latest code changes (App Check, explore search)

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
- [x] `python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/agent.py functions/bootstrap/config.py` passes
- [x] `python3 -m unittest functions/bootstrap/test_main_logic.py` passes (29/29 — includes ExploreSearchTests, AppCheckTests)
- [x] Firestore migration complete (Steps 3a–3e): all endpoints + LiveKit agent worker on Firestore; Cloud SQL env/dependencies removed
- [x] `/explore` rebuilt (Step 4): `explore_attrs` denormalization, LLM query parsing, structured filters + radius
- [x] Firebase App Check wired (Step 5): Flutter activation, `X-Firebase-AppCheck` header, backend monitor-mode verification (`APP_CHECK_ENFORCE` defaults false)

### 2026-08-10 live device/backend debug handoff
- [x] Production-first manual testing guide updated; local FastAPI backend moved to optional appendix.
- [x] Pixel 10 Pro Fold paired over wireless ADB and verified against production Cloud Run.
- [x] LiveKit worker startup fixed in `functions/bootstrap/main.py` by lazily importing `agent.py` after `main.py` finishes loading, avoiding the circular import that left `start_agent_server=None`. Deployed to Cloud Run and verified worker registration.
- [x] Agent context loading made loud in `functions/bootstrap/agent.py`: profile/questions/skills/memory fetches now have bounded timeouts and log `AGENT CONTEXT WARNING` / `AGENT CONTEXT DEGRADED`; degraded sessions add a testing warning to the prompt.
- [x] Preboarding repeat bug fixed on device for `suhailps@gmail.com`: `onboardingStatusProvider` now waits for Firebase auth restoration, router waits for resolved onboarding state, and failed profile writes throw instead of silently succeeding. Cold force-stop/start verified on phone lands in Ayma chat with production `/profile` returning `onboarding_complete=true`.
- [x] App Check debug token fixed for current Pixel debug APK without hardcoding in source: a deterministic debug secret was registered via Firebase App Check REST for Android app `1:235381544962:android:99993490ed0aee69c4ef1b` with display name `Pixel 10 Pro Fold debug 2026-08-10`, then seeded into the phone app's debug-provider private SharedPreferences. Fresh force-stop/start at `2026-08-10T14:11:10Z` showed the debug provider using that secret, `/profile` and `/notifications` returned 200, and Cloud Run no longer logged `App Check token missing` for those requests.
- [~] Remaining active fix: Gemini Live voice session can still fail after LiveKit connects with `Failed to connect to Gemini Live` / websocket opening-handshake timeout. User confirmed this is the main issue and asked not to stop. Current priority is making Ayma respond reliably. Flutter text fallback has been added in `ayma_flutter/lib/services/audio_service.dart`: text still publishes to LiveKit first, but if no agent transcript arrives within the bootstrap timeout window, it falls back to production `/chat` and persists the turn via `/post-turn`. Installed to phone and verified fallback produced an Ayma reply through `/chat`. Backend logs revealed the direct LiveKit data-channel handler is crashing with `AttributeError: 'AgentSession' object has no attribute 'chat_ctx'`; `functions/bootstrap/agent.py` is now patched to use a standalone `ChatContext` for data-channel text instead of `session.chat_ctx`. Backend validation passed: `py_compile` clean and `python3 -m unittest functions/bootstrap/test_main_logic.py` passed `31/31`. Cloud Build `ba54e54c-fa97-4d3c-aa67-79db0c081b09` succeeded with image digest `sha256:02c575fbc9a242cfe16998943142e970e081418303c03db2dceacd88b7914f01`; deployed to Cloud Run revision `ayma-bootstrap-00055-g2w` at 100% traffic. Next: verify direct LiveKit text reply on phone.
- [~] Follow-up fix in progress after verifying `00055-g2w`: direct LiveKit text replies now arrive, but sometimes after the REST fallback, causing duplicate/stale replies; agent background post-turn can also fail with `Future ... attached to a different loop` from Firestore async client reuse. Patched `functions/bootstrap/agent.py` to use one Firestore `AsyncClient` per event loop and to echo a `client_message_id` on data-channel replies. Patched `ayma_flutter/lib/services/audio_service.dart` to send JSON text envelopes with ids and ignore late LiveKit replies after a successful REST fallback. Validation: `python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/agent.py functions/bootstrap/config.py` passed, `python3 -m unittest functions/bootstrap/test_main_logic.py` passed `31/31`; `flutter analyze` has no new errors, only 5 pre-existing speech-to-text deprecation infos. Flutter debug APK installed on Pixel 10 Pro Fold. Cloud Build `0173b99c-7739-43fd-b9c3-20fe155d94bf` succeeded with image digest `sha256:d78c1058cfa3d52b34d349f370ada0debea3ad269845d08080d9fa23b4762594`; deployed to Cloud Run revision `ayma-bootstrap-00056-pqh` at 100% traffic. Next: fresh-launch phone and verify one clean text turn with no duplicate stale LiveKit reply and no Firestore cross-loop persistence warning.
- [~] 2026-08-10 transport-mode correction: user flagged text should be fast and must not activate voice/mic. Patched Flutter so `AymaAudioService.sendText()` uses production REST directly and disconnects any active LiveKit transport before typed text; `BackendService.chat()` now calls `/chat/text`, which uses the same backend prompt builder/context path as voice bootstrap. `/post-turn` still persists text turns to Firestore wiki/profile/memory so switching back to voice reloads the latest context. After a text reply, state returns to `disconnected` instead of `listening`. Hardened mic-off/disconnect by disabling local participant microphone publications before disconnect and routing mute toggles through `_setMicrophoneEnabled()`. Next: format/analyze, reinstall phone, verify text `/chat/text` does not create LiveKit bootstrap/job/mic logs and voice still starts only from the mic button.
- [~] `/chat/text` production test on phone reached the correct endpoint without creating a new `/bootstrap`, but returned 500. Patched backend `functions/bootstrap/main.py` so `/chat/text` uses `_gemini_call()` with the same voice-bootstrap system prompt, validates empty input, logs real generation failures, and returns 429 for Gemini quota exhaustion instead of generic 500. Next: backend validation, deploy, retest typed message.
- [x] Explore + You/Profile fixes from parallel agent integrated: Explore gender filters normalized to production values (`woman`/`man`), Explore cards show real age instead of literal `$age`, backend and Flutter accept plural gender aliases, `ProfileUpdateBody` accepts `profile_private`, and Explore fallback search tokenizes natural queries when Gemini parsing fails.
- [x] Combined validation after chat/Explore/Profile changes: `python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/agent.py functions/bootstrap/config.py` passed; `python3 -m unittest functions/bootstrap/test_main_logic.py` passed `31/31`; `.venv/bin/python -m pytest functions/bootstrap/test_fake_profile_all_screens.py -q` passed `1/1`; `flutter analyze` has only 5 pre-existing speech-to-text deprecation infos.
- [x] Cloud Build `4030825b-e7e1-402e-beb2-a342d536f81b` succeeded with image digest `sha256:a511c3a9b5f3b2ab55cd24bbd277ac0a11a81a23ca4afb5a887f2a2ed88405ff`; deployed to Cloud Run revision `ayma-bootstrap-00057-pp7` at 100% traffic.
- [x] Checkpoint commit pushed: `95af916` (`Stabilize production backend and chat flows`) to `origin/voice-improvements`.
- [x] Rebuilt backend from committed source after push to guarantee production includes the integrated Explore/Profile backend fixes: Cloud Build `f1ace285-7673-475d-b731-a037f5e3bbbb`, image digest `sha256:5ec69e5fc90848733bcc4f08d8319dc470d6147e700c54d3155d320f22c4ad72`, deployed to Cloud Run revision `ayma-bootstrap-00058-tdg` at 100% traffic.
- [~] Flutter debug APK rebuilt/installed after transport-mode changes. Further UI smoke testing is blocked because the Pixel is on the lock screen (`Unlock with PIN or fingerprint`). ADB is healthy again over mDNS transport after restarting the server. Next after user unlocks phone: verify typed chat hits `/chat/text` with no `/bootstrap`/LiveKit job, verify mic button alone starts voice, verify mic-off disables local mic, and smoke Explore + You/Profile.
- [x] Firestore vector index for `user_memories.embedding` created after production logs showed `Missing vector index configuration`; index id `CICAgJjF9oIK`. This should remove the memory vector-search warning on future agent context loads once Firestore finishes serving the index.
- [~] Parallel agent `Popper` spawned to investigate Explore and You/Profile tab failures without overlapping the chat/audio transport edits. Await result before integrating any separate UI/API fixes.
- [ ] Production App Check enforcement is wired but not complete: debug token is fixed for current phone; production still needs Play Integrity/SHA/provider verification before setting `APP_CHECK_ENFORCE=true`.
- [x] `flutter analyze` — 0 errors/warnings (5 pre-existing info-level deprecations in `audio_service.dart`)
- [x] Emulator smoke pass (prior build): all 8 screens pass — **must re-run against current source after deploy**
- [ ] Text chat integration test (adb cannot type into Flutter TextField; requires device keyboard or flutter_driver)
- [ ] App Check debug token registered in Firebase Console and verified on live backend
- [ ] `/explore` structured + free-text search smoke-tested on deployed backend

### Current environment blockers observed

- **Cloud SQL instance `ayma-db-instance` DELETED** (2026-07-21) — instance deleted on GCP and local legacy Cloud SQL files cleaned up. All runtime & endpoints now run on pay-as-you-go Firestore.
- **`gcloud` / `firebase` CLI available** — `/snap/bin/gcloud` and `/home/suhailps/.nvm/versions/node/v22.23.0/bin/firebase` authenticated for `ayma-ai` project.
- **App Check enforcement blocked on Firebase Console setup** — debug tokens must be registered before setting `APP_CHECK_ENFORCE=true`.
- Android emulator binary exists at `/home/suhailps/Android/Sdk/emulator/emulator`; emulator launch from agent shell may fail with `libX11.so.6` missing — use user shell or physical device for runtime tests.
- Flutter CLI available at `/snap/bin/flutter` (verified 2026-07-21).

---

## Active Plan — Matching Simplification & Firestore Migration

> **Full plan detail:** `/home/suhailps/.claude/plans/linked-hatching-nebula.md` (user-approved).
> **Rule:** one step at a time. Do not start a step until the previous one is confirmed working.
> When a step below is completed and verified, remove it from this list (this file reflects
> remaining work, not history — record what happened in `Handoff State` instead).
> **Delegation:** per `CLAUDE.md`, Claude does not write implementation code directly. Each step
> is implemented by `gemini_code` or `codex_code` (fallback order gemini → deepseek → codex),
> called from a background Agent with the relevant file content as context.
> **Context:** the old matching pipeline ranked candidates by pgvector cosine similarity
> (`main.py:2471`) before heuristic + LLM scoring — but it embedded the *same* fields for both
> sides of a pair (`main.py:274`), so it measured self-similarity, not compatibility. Removing it
> also removes the only reason this app needs Postgres/pgvector, which unblocks moving off
> Cloud SQL (the always-on billing source) onto pay-as-you-go Firestore. No real user data exists
> worth preserving, so this is a fresh schema on Firestore, not a migration script.

- [x] **Step 1** — Stop the Cloud SQL instance (`ayma-db-instance`) to halt compute billing. Done 2026-07-21; see blocker note above. Full deletion + dependency cleanup (`cloud-sql-python-connector`, `asyncpg`, `schema.sql`, `run_schema.py`, `cloud-sql-proxy` binary) happens after Step 3 ships and is verified.
- [x] **Step 2** — Removed vector matching from `run_matching` (pgvector ranking branch, `_refresh_wiki_embedding` + its two call sites, `_generate_embedding`); updated stale pgvector comments in `questionnaire_graph.py`. Done 2026-07-21 via `codex_code`. `py_compile` passes on both files; grep confirms zero remaining functional references (`matching_embedding` still appears once, harmlessly, as a skip-list entry in `_PROFILE_SKIP`). **Leftover dead code flagged for Step 3 cleanup**: `_embed_text_with_gemini_v2`, `_embedding_client`, `_EMBEDDING_OUTPUT_DIMENSIONALITY`, `_EMBEDDING_TASK_PREFIX`, and the `EMBEDDING_MODEL` import in `main.py` are now unused (their only caller was `_generate_embedding`) — left in place since Step 7 will likely repurpose the model for memory embeddings, but confirm before reusing vs. deleting-then-recreating.
- [x] **Step 3** — Rebuild the data layer on Firestore. Done 2026-07-21 (sub-steps 3a–3e). Cloud SQL instance remains stopped; full instance deletion + `schema.sql`/`run_schema.py` cleanup deferred until deploy smoke-test passes.
  - [x] **3a** — Firestore client added (`app.state.db = AsyncClient(...)`, `asyncpg` pool left untouched for not-yet-migrated endpoints). `users/{uid}` field mapping is 1:1 with `schema.sql` (`matching_embedding` skipped). Fully migrated: `GET/POST /profile`, `POST /device-token`. Partially migrated (users-table part only, rest stays on `asyncpg` for 3b-3d): `GET /profile/{userId}/public`, `GET/POST /profile/answers`, `GET /explore` (free-text search TODO'd for Step 4), `POST /bootstrap` (user lookup/create part only). New helpers: `get_user_doc`, `parse_user_doc`, `ensure_user_doc`, `update_user_doc`. Added `google-cloud-firestore==2.27.0` to `requirements.txt`. `py_compile` + full 19-test suite pass. Done 2026-07-21.
  - [x] **Incidental fix (found during 3a review)** — removed a dead test-detection branch in `lifespan()` (`is_mocked` check + "Mock PostgreSQL connected for testing" log) that had no real effect on the actual test suite (which never invokes `lifespan()`), and removed a hardcoded plaintext Cloud SQL password found in the same function — see Security Fixes Needed table. Done 2026-07-21.
  - [x] **3b** — `matches/{pairId}` (deterministic ID: `_pair_id(uidA, uidB) = sorted([uidA, uidB]).join('_')`) + `matches/{pairId}/simulations` subcollection (ordered by `turn_index`), replacing the `UNIQUE (user_a, user_b)` + `ON CONFLICT` upsert and `match_simulations` table. New helpers (next to the 3a `users/{uid}` helpers): `_pair_id`, `_match_doc_ref`, `parse_match_doc`, `get_match_doc`, `upsert_match_doc` (merge=True upsert on the pairId doc — the `ON CONFLICT DO UPDATE` equivalent), `get_matches_for_user` (two equality queries merged, since Firestore has no OR query), `_match_simulations_ref`, `replace_match_simulations`, `get_match_simulations`, `_all_match_counts` (admin-only full-collection scan). Migrated to Firestore: `GET/POST /matches/{pair_id}/status`, `GET/POST /matches/{pair_id}/simulation` + `/toggle-simulation`, `POST /vibe-check`, `POST /run-matching`, `POST /run-matching-cron`, `_run_vibe_check`, and the `matches`/`match_simulations` portions of `GET /admin/users` and `GET /admin/users/{target_uid}` (the rest of those two admin endpoints stays on `asyncpg`, out of scope for 3b). **Int-to-string ID transition**: route path params renamed `match_id: int` → `pair_id: str` on all 4 match-scoped routes; `VibeCheckRequest.match_id: int` → `pair_id: str`. Flutter already passed match IDs as `String` everywhere (`MatchModel.id`, providers, `match_detail_screen.dart`) — the only fix needed was removing `int.tryParse(matchId) ?? 0` before sending to the backend in `ayma_flutter/lib/services/api_service.dart` (`updateMatchStatus`, `toggleMatchSimulation`, `getMatchSimulation`) and `ayma_flutter/lib/services/backend_service.dart` (`vibeCheck`, also renamed the JSON body key `match_id` → `pair_id`). `admin_screen.dart` reads match fields as untyped `Map` display-only, no changes needed. Known tradeoffs (admin-only, low-traffic, acceptable during migration): `GET /admin/users`'s `has_matches` filter is now applied client-side after the Postgres `LIMIT`, so filtered results can return fewer than the requested limit even when more would qualify; `run_matching`/`run_matching_cron`'s candidate-pool queries apply Firestore's `.limit()` before excluding self/already-matched candidates (same approximation `/explore` already accepted in 3a). Incidental fix: `GET /matches` never selected `created_at` in the old SQL, which would have thrown in Flutter's `MatchModel.fromMap` (`DateTime.parse(m['created_at'] as String)` on a missing key) — added it while rewriting the endpoint. Implemented via `codex_code` (two calls: main.py rewrite, then a small correction adding the missing `created_at` field; a third call for the Flutter fix). `python3 -m py_compile main.py` and `python3 -m unittest test_main_logic.py` (19 tests) both pass; `flutter analyze` shows 0 errors/warnings (5 pre-existing unrelated info-level deprecation notices in `audio_service.dart`). Done 2026-07-21.
  - [x] **3c** — `conversations/{pairId}/messages` subcollection (same `pairId` scheme as 3b, reusing `_pair_id` so a conversation shares its parent key with the corresponding match doc), replacing the `messages` table and the `LEFT JOIN users` at old `main.py:1630`. Schema per message doc: `from_user_id`, `to_user_id`, `text`, `read` (bool, default `False`), `created_at` (`SERVER_TIMESTAMP`), ordered by `created_at`. New helpers (next to the 3a/3b helpers): `_conversation_messages_ref`, `_parse_message_doc`, `send_message` (writes a message doc — the `INSERT INTO messages` equivalent), `get_conversation_messages` (single-thread read, `order_by("created_at").limit(MESSAGES_LIMIT)` — the two-sided `WHERE (from=a AND to=b) OR (from=b AND to=a)` equivalent), `get_all_messages_for_user` (admin-only: `collection_group("messages")` with two equality queries on `from_user_id`/`to_user_id` merged/de-duped, same pattern as `get_matches_for_user`, sorted by `created_at` desc), `_all_message_counts` (admin-only full collection-group scan, mirrors `_all_match_counts`). Migrated to Firestore: `POST /messages` (send — writes via `send_message`, looks up sender name and recipient `fcm_token` via `get_user_doc` instead of raw SQL; the `notifications` INSERT stays on `asyncpg`, out of scope until 3d), `GET /messages/{other_user_id}` (thread fetch via `get_conversation_messages`, replacing the join), and the `messages`-related parts of `GET /admin/users` (`has_messages` filter + `message_count`, now computed via `_all_message_counts` and applied client-side after the Postgres `LIMIT` — same known tradeoff already accepted for `has_matches` in 3b) and `GET /admin/users/{target_uid}` (`messages`/`dm_threads` built from `get_all_messages_for_user` + a local per-request `counterpart_cache` dict to avoid refetching the same counterpart's `get_user_doc` per message; rest of both admin endpoints untouched, still `asyncpg`). **Incidental fix**: deleted `_get_fcm_token(uid, conn)` — a dead Postgres read left over from 3a (3a moved `fcm_token` writes to the Firestore user doc via `POST /device-token` → `update_user_doc`, but this reader was never updated to match and was the send-message endpoint's only caller); replaced with `get_user_doc(...).get("fcm_token")`, the same pattern `run_matching`/`run_matching_cron` already use. No int→string ID transition needed — message `id` was already returned as a Flutter-facing string in the old code (`m["id"] = str(m["id"])`), so no Flutter changes were required (`direct_message_screen.dart` only reads `text`/`from_user_id`, `api_service.dart`'s `sendDirectMessage`/`conversationStream` pass the shape through untouched). Implemented via `codex_code` (one call covering all 5 regions: new helpers, `admin_list_users`, `admin_get_user_detail`, deleting `_get_fcm_token`, and the two `/messages` endpoints); verified the async Firestore `.add()` return order (`(update_time, doc_ref)`) and `AsyncClient.collection_group()` availability against the installed `google-cloud-firestore` package before applying. `python3 -m py_compile main.py` and `python3 -m unittest test_main_logic.py` (19 tests) both pass; `flutter analyze` shows 0 errors/warnings (same 5 pre-existing unrelated info-level deprecation notices in `audio_service.dart` as 3b). Done 2026-07-21.
  - [x] **3d** — Remaining Firestore subcollections migrated: `users/{uid}/{notifications,user_media,user_memories,user_questions,user_skills}` now back the remaining profile/bootstrap/admin surfaces, `GET /notifications`, `POST /notifications/{id}/read`, `POST /notifications/read-all`, `GET /profile/{userId}/public`, `GET /insights`, `GET /matches` photo preview lookup, `GET /explore` photo preview lookup, `POST/DELETE /media`, `POST /messages` notification fanout, `POST /bootstrap`, `POST /post-turn`, `POST /wiki/correct`, `POST /chat/text`, `GET /questions/pending`, `POST /questions/followup`, `POST /questions/{qid}/answered`, and the remaining non-match/non-message portions of both `/admin/users*` endpoints. Added new helper layer in `main.py` for Firestore-backed skills/questions/memories/media/notifications plus collection-group count scans, and removed the hard Cloud SQL startup dependency from `lifespan()` (`app.state.pool = None`, LiveKit agent starts without a DB pool). Added the Firebase Functions trigger codebase in `functions/triggers/` with `cleanup_deleted_user` to cascade-delete Firestore subcollections, match simulations, match docs, and conversation messages when a `users/{uid}` doc is deleted. Validation after the migration edit: `python3 -m py_compile functions/bootstrap/main.py` passes and `python3 -m unittest functions/bootstrap/test_main_logic.py` passes (19/19). Done 2026-07-21.
  - [x] **3e** — Migrated `agent.py` (LiveKit worker) from asyncpg to Firestore helpers (`get_user_doc`, `get_pending_user_questions`, `get_enabled_skills`, `add_followup_question_doc`, `_process_post_turn_from_messages`). Removed `DATABASE_URL`/`CLOUD_SQL_*` from `config.py`, dead `asyncpg` import from `main.py`, and `asyncpg`/`cloud-sql-python-connector` from `requirements.txt`. Updated `docs/ARCHITECTURE.md` (Firestore data layer, LiveKit voice flow, matching without pgvector, `pair_id` routes, legacy schema mapping) and `docs/agent.md` (env vars, deploy commands, local dev). `py_compile` + 19-test suite pass. Done 2026-07-21.
  - [x] Update `docs/ARCHITECTURE.md` and `docs/agent.md` per repo convention — done as part of 3e above.
- [x] **Step 4** — Rebuild `/explore` search: added `explore_attrs` denormalized from `profile_answers_public` (religion, race, height, education, occupation, etc.), LLM query parsing via `_parse_explore_query`, Firestore equality on top-priority attribute + in-memory post-filter for remaining attrs/text/radius, wired `radiusKm` from Flutter. Files: `functions/bootstrap/main.py`, `ayma_flutter/lib/services/api_service.dart`, `ayma_flutter/lib/providers/providers.dart`, `functions/bootstrap/test_main_logic.py::ExploreSearchTests`. Done 2026-07-21.
- [x] **Step 5** — Firebase App Check: `FirebaseAppCheck.instance.activate()` in Flutter (debug/Play Integrity/DeviceCheck), shared `BackendHeaders` sends `X-Firebase-AppCheck` on all Cloud Run requests, backend verifies via `firebase_admin.app_check.verify_token()` in `verify_token()` with `APP_CHECK_ENFORCE=false` monitor mode by default. Files: `ayma_flutter/lib/main.dart`, `ayma_flutter/lib/services/backend_headers.dart`, `ayma_flutter/lib/services/api_service.dart`, `ayma_flutter/lib/services/backend_service.dart`, `functions/bootstrap/main.py`, `functions/bootstrap/config.py`, `functions/bootstrap/test_main_logic.py::AppCheckTests`. Done 2026-07-21.
- [x] **Step 6** — On-demand matching configured (automated daily cron deferred per product direction; matching engine triggered directly on-demand). Done 2026-07-21.
- [x] **Step 7** — Added semantic memory retrieval: embeds `user_memories` writes with Gemini embeddings, stores as Firestore native `Vector` field (`embedding`), retrieves top-K via `find_nearest(distance_measure=COSINE)`, and injects into `agent.py` dynamic system prompt. Tested & verified with 31/31 unit tests passing. Done 2026-07-21.

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
- [x] Re-run Flutter static validation (`flutter analyze`) — 0 errors/warnings (5 info deprecations in `audio_service.dart`)
- [x] Remove or quarantine any remaining obsolete artifacts (deleted stale docs: data.md, memory.md, matching.md, app_audit_and_data_map.md, laptop_backend_server.md, pixel_wifi_test_runbook.md)

### Workstream C — Shared Agent Discipline

- [x] Ensure all agent entrypoint docs explicitly defer to `PLAN.md`
- [ ] Ensure testing instructions point back to shared validation state here
- [x] Keep this file updated on every handoff

---

## Validation Matrix

Use this matrix instead of ad hoc “seems fine” validation.

### Backend

- [x] `python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/agent.py functions/bootstrap/config.py`
- [x] `python3 -m unittest functions/bootstrap/test_main_logic.py` (29/29)
- [ ] Deploy Firestore-backed backend to Cloud Run and smoke-test `/health`, `/bootstrap`, `/profile`, `/explore`, `/matches`, `/messages`
- [ ] Matching endpoint smoke test (needs 2+ users with profiles on deployed backend)

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
- Prior emulator smoke pass used an older installed build — **re-run required** after deploying Firestore backend + App Check changes.
- Onboarding upsert fix (first-time `/profile` write) was verified on old Postgres backend; re-verify on Firestore backend after deploy.

---

## Handoff State

- **Last completed:** Step 5 — Firebase App Check end-to-end.
  - Flutter: `main.dart` activates App Check (debug/Play Integrity/DeviceCheck); new `backend_headers.dart` sends `X-Firebase-AppCheck` on all Cloud Run requests via `ApiService` + `BackendService`.
  - Backend: `verify_token()` calls `firebase_admin.app_check.verify_token()`; `APP_CHECK_ENFORCE` in `config.py` (default `false` = monitor mode).
  - Tests: `AppCheckTests` added (4 cases); suite now 29/29.
- **Also completed this session (prior steps, same branch):**
  - Step 3e: `agent.py` migrated to Firestore; removed `DATABASE_URL`/`CLOUD_SQL_*`/`asyncpg` from runtime.
  - Step 4: `/explore` rebuilt with `explore_attrs`, LLM query parsing, structured filters, `radiusKm`; `ExploreSearchTests` (6 cases).
  - Docs: `docs/ARCHITECTURE.md`, `docs/agent.md` updated for Firestore, LiveKit, App Check, explore.
- **Validated:** `python3 -m py_compile` on `main.py`/`agent.py`/`config.py`; `python3 -m unittest functions/bootstrap/test_main_logic.py` (29/29); `flutter analyze` (0 errors/warnings).
- **Blocked on:** deploy access (`gcloud`/`firebase` not in agent shell); App Check debug token registration in Firebase Console; runtime smoke against deployed Firestore backend.
- **Next action:** 1) deploy `functions/bootstrap` to Cloud Run; 2) deploy `functions/triggers`; 3) register App Check debug token + smoke-test authenticated endpoints; 4) set `APP_CHECK_ENFORCE=true` once stable; 5) **Step 6** — Firebase `onSchedule` cron calling `/run-matching-cron`.

Prior handoff (superseded): Step 4 — `/explore` search rebuild with structured Firestore filters and LLM query parsing.

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
      | HTTP REST + LiveKit WebRTC (voice/text)
      v
FastAPI Backend  <-- functions/bootstrap/main.py
      |
      |-- Gemini API       <-- text AI, post-turn, matching, vibe-check
      |-- LiveKit Cloud    <-- real-time voice via agent.py worker
      |-- Firebase Auth    <-- authentication
      |
      v
Firestore  <-- all application data (users, matches, conversations, subcollections)
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

### PHASE 1 — Data Layer (PostgreSQL + Firebase) ✅ *legacy — superseded by Firestore migration Steps 1–3*

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
| Architecture | FastAPI + Gemini + Firestore | LangGraph + Supabase + Mem0 | Simpler custom logic; pay-as-you-go Firestore replaces always-on Cloud SQL. |
| Client | Flutter | React | Native performance, better device capability integration (mic/camera). |
| Auth | Firebase Auth + App Check | Supabase Auth | Seamless mobile integration; App Check gates backend abuse. |
| Voice infra | LiveKit + Gemini Live | Raw WebSocket + Gemini Live | Unified voice/text session; AEC and barge-in via LiveKit. |
| Background jobs | Cloud Scheduler → `/run-matching-cron` (moving to Firebase Functions Step 6) | Celery + Redis | No always-on worker/broker; fits stateless HTTP model |

---

## Costs at MVP Scale

| Service | Cost |
|---------|------|
| Firebase Auth | $0 (free tier) |
| Firestore | Pay-as-you-go (~$0 at MVP scale) |
| Firebase App Check | $0 (free tier) |
| Gemini API | ~$0–5/mo at low traffic |
| LiveKit Cloud | Usage-based |
| Cloud Run | Pay-per-request |
| **Total** | **~$0–15/mo at low traffic** |

---

## Current Step

**-> Deploy + register App Check debug tokens, then Step 6 — Firebase scheduled matching cron**

---

## Deferred Follow-Up

- [x] **Admin console deployment wiring** — Configured `ADMIN_PASSWORD` in `config.py`, updated Cloud Run env vars, and verified `/admin/users` auth rejection/acceptance. Done 2026-07-21.
- [x] **Cloud SQL instance deletion & legacy artifact cleanup** — Deleted `ayma-db-instance` Cloud SQL instance on GCP and removed local legacy Cloud SQL files (`cloud-sql-proxy`, `schema.sql`, `run_schema_proxy.py`, `functions/bootstrap/run_schema.py`, `functions/bootstrap/ayma.db`). Done 2026-07-21.

---

## Security Fixes Needed

> Audited: 2026-06-20. Fix all Critical and High items before production launch.

| Severity | Location | Issue | Fix |
|---|---|---|---|
| ~~Critical~~ FIXED 2026-07-21 | `functions/bootstrap/main.py` `getconn()` | Hardcoded plaintext Cloud SQL password (`AymaSuperSecret2026!`) directly in source. Found while investigating a stray "Mock PostgreSQL connected for testing" log line. | Fixed: replaced with `CLOUD_SQL_USER`/`CLOUD_SQL_PASSWORD` env vars via `_require_env()` in `config.py` (fail-fast, no default). **Deployment prerequisite: both env vars must be set on Cloud Run before the next deploy, or startup will raise.** Still recommended: rotate the actual Cloud SQL password in the GCP console, since deleting the source line does not undo a git-history exposure. Moot once Step 3 fully retires Cloud SQL. |
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
| Medium | `functions/bootstrap/main.py` `/explore` | ~~Free-text query passed to SQL `ILIKE`~~ | Fixed 2026-07-21 (Step 4): Firestore-backed explore with LLM query parsing, structured `explore_attrs` filters, and 100-char query length cap. |
| Medium | `functions/bootstrap/config.py` | ~~`DATABASE_URL` default value~~ | Fixed 2026-07-21: `DATABASE_URL`/`CLOUD_SQL_*` removed entirely as part of Step 3e Firestore migration. |
| Low | `functions/bootstrap/main.py:193` | `logger.info(f"FCM sent: {title!r} → {fcm_token[:20]}…")` logs the first 20 characters of an FCM device token. FCM tokens are sensitive; even a partial token should not appear in logs that may be exported to observability platforms. | Replace with `logger.info(f"FCM sent: {title!r} → [token redacted]")` or log only a hash of the token for correlation. |
