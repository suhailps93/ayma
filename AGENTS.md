# AGENTS.md

Canonical plan and repo context live in `PLAN.md`, `docs/agent.md`, and `docs/ARCHITECTURE.md`. Read those first. This file only adds Cursor Cloud environment notes.

## Cursor Cloud specific instructions

The startup update script already refreshes Python and Flutter dependencies. The items below are durable, non-obvious notes for running the two services in the Cloud VM. Standard commands are documented in `README.md`, `docs/agent.md`, and `CLAUDE.md` — prefer those.

### Services

- **Backend**: FastAPI (`functions/bootstrap/main.py`), Python 3.12, deps in a venv at `functions/bootstrap/.venv`.
- **Frontend**: Flutter app (`ayma_flutter/`). No Android emulator is available in the Cloud VM; run it as a **web** app (Chrome + `web/` support are installed).
- **Database**: local PostgreSQL 16 with the `pgvector` extension. Database `ayma` (user `postgres` / password `postgres`) has `schema.sql` already applied.

### Cost-safe local test mode (avoid GCP bills)

Production uses two **billed** GCP services that should stay **off** during dev/testing:
- **Cloud SQL for PostgreSQL** (`ayma-ai:us-central1:ayma-db-instance`, the "Google database") — bills 24/7 for the instance. Replaced locally by the VM's PostgreSQL (`ayma` DB).
- **Cloud Run `ayma-bootstrap`** (`https://ayma-bootstrap-...run.app`) — the FastAPI backend. Replaced locally by uvicorn.

Gemini is the only remaining paid dependency and is **pay-per-call** (not always-on): non-AI endpoints work with a placeholder `GOOGLE_API_KEY`; only real chat/voice/matching calls cost money. Note voice uses a Gemini key baked into `lib/env.dart` and streams **directly** from the app to Google (bypasses the backend), so voice always bills Gemini regardless of backend.

- **Backend, no GCP:** `functions/bootstrap/run-local` — starts local Postgres + uvicorn (hot reload) with local `DATABASE_URL` and a dummy `GOOGLE_API_KEY`. Export a real `GOOGLE_API_KEY` first only if you need real AI.
- **Web frontend, no GCP:** point it at the local backend (see the frontend run command below).
- **Phone testing, no GCP:** run `run-local`, expose it with a free tunnel (`cloudflared tunnel --url http://localhost:8080`, no account needed — `cloudflared` is installed), then build the APK against that URL: `ayma_flutter/scripts/deploy-to-phone --backend https://<sub>.trycloudflare.com "notes"`. The phone then hits the VM's local backend + Postgres. The tunnel URL is regenerated each `cloudflared` run, so rebuild the APK when it changes.
- Do **not** run `gcloud run deploy`, start Cloud SQL, or use the `cloud-sql-proxy` for routine testing — those are the billed paths.

### Non-obvious startup caveats

- **Flutter lives at `~/flutter`** (git clone, channel stable) and is added to `PATH` via `~/.bashrc`. If `flutter` is not found in a fresh non-login shell, run `export PATH="$HOME/flutter/bin:$PATH"`.
- **PostgreSQL does not auto-start.** Start it each session before running the backend: `sudo pg_ctlcluster 16 main start`.
- **The backend requires env vars at import time or it will not boot:**
  - `GOOGLE_API_KEY` is read with `os.environ[...]` at import — the process crashes on startup if it is unset. For local dev without real AI calls, any non-empty placeholder works (e.g. `GOOGLE_API_KEY=dummy-key-for-local-dev`).
  - `DATABASE_URL` — the lifespan handler connects to Postgres on startup and there is **no mock/SQLite fallback** in the current `main.py` (the `USE_MOCK_DB` / `mock_db.py` path referenced in some older docs does not exist here). Use `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/ayma`.
  - `ADMIN_PASSWORD` — set it (e.g. `localadmin`) to use the password-gated `/admin/*` endpoints and the Flutter admin console.
- Run the backend: easiest is `functions/bootstrap/run-local` (handles Postgres + env). Manual equivalent: from `functions/bootstrap/`, activate `.venv`, export the vars above, then `uvicorn main:app --host 0.0.0.0 --port 8080`. Health check: `curl http://localhost:8080/health`.
- Run the frontend against the local backend: `cd ayma_flutter && flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8090 --dart-define=AYMA_BOOTSTRAP_URL=http://localhost:8080`. Backend CORS is `allow_origins=["*"]`, so the browser can call `localhost:8080` directly.

### Iterating on the Flutter app and deploying to a physical phone

The Cloud VM is not on the developer's local network, so direct/wireless `adb` to the phone is not possible from here. Instead, iterate by building an installable APK in the VM and getting it onto the phone. Helper: `ayma_flutter/scripts/deploy-to-phone ["release notes"]`.

- The Android SDK (cmdline-tools, platform-tools, build-tools 35/36, platform android-35/36, NDK `28.2.13676358`) is installed at `~/Android/Sdk` and exported in `~/.bashrc`. The `firebase` CLI is installed via npm at `~/.npm-global/bin` (also on `PATH` via `~/.bashrc`).
- `flutter build apk --release` works out of the box: `android/app/build.gradle.kts` signs the release build with the **debug** key, so the APK installs on any phone with "install unknown apps" enabled. The first Gradle build is slow (~4–5 min); subsequent incremental builds are ~10–15s thanks to the warm `~/.gradle` cache (persisted in the VM snapshot).
- By default the app talks to the **production Cloud Run backend** (`Env.bootstrapUrl`) — this incurs Cloud Run + Cloud SQL cost and only works while those are running. For **cost-safe** phone testing, use the local backend + tunnel path via `deploy-to-phone --backend <tunnel-url>` (see "Cost-safe local test mode"). To target any other backend directly, add `--dart-define=AYMA_BOOTSTRAP_URL=...`.
- Two delivery paths, both handled by the script:
  1. **Manual (always works, no secrets):** the script copies the APK to `/opt/cursor/artifacts/ayma-app-release.apk`, which is downloadable from the Cursor web app. Download it on the phone and install.
  2. **Automated push (Firebase App Distribution):** if `FIREBASE_TOKEN` (from `firebase login:ci`) or `GOOGLE_APPLICATION_CREDENTIALS` (service account with the *Firebase App Distribution Admin* role) is set, the script uploads the build so registered tester phones get it automatically. Set `AYMA_FAD_TESTERS=you@example.com` (and/or `AYMA_FAD_GROUPS`). The Android Firebase app id is `1:235381544962:android:99993490ed0aee69c4ef1b`.
- The close-the-loop cycle: edit Dart in `ayma_flutter/lib/` → `scripts/deploy-to-phone "what changed"` → install/receive on phone → test → repeat.

### Testing / validation without external credentials

- Backend logic tests are self-contained (they stub FastAPI, Firebase, Gemini, asyncpg): `functions/bootstrap/.venv/bin/python -m unittest functions/bootstrap/test_main_logic.py`.
- `flutter analyze` currently reports ~7 `info`-level deprecation notices (from the newer stable Flutter 3.44.4 SDK), with **0 errors and 0 warnings** — exit code is 0. These are SDK-version deprecations, not code defects.
- Most REST endpoints require a real Firebase ID token (`verify_token`) and Gemini API access, so full auth/chat/voice/matching E2E needs `GOOGLE_API_KEY` (Gemini) plus a Firebase test account. The **`/admin` console** (password-gated, no Firebase login) is the best way to exercise the client → backend → Postgres path without those secrets.
