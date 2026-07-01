# AGENTS.md

Canonical plan and repo context live in `PLAN.md`, `docs/agent.md`, and `docs/ARCHITECTURE.md`. Read those first. This file only adds Cursor Cloud environment notes.

## Cursor Cloud specific instructions

The startup update script already refreshes Python and Flutter dependencies. The items below are durable, non-obvious notes for running the two services in the Cloud VM. Standard commands are documented in `README.md`, `docs/agent.md`, and `CLAUDE.md` — prefer those.

### Services

- **Backend**: FastAPI (`functions/bootstrap/main.py`), Python 3.12, deps in a venv at `functions/bootstrap/.venv`.
- **Frontend**: Flutter app (`ayma_flutter/`). No Android emulator is available in the Cloud VM; run it as a **web** app (Chrome + `web/` support are installed).
- **Database**: local PostgreSQL 16 with the `pgvector` extension. Database `ayma` (user `postgres` / password `postgres`) has `schema.sql` already applied.

### Non-obvious startup caveats

- **Flutter lives at `~/flutter`** (git clone, channel stable) and is added to `PATH` via `~/.bashrc`. If `flutter` is not found in a fresh non-login shell, run `export PATH="$HOME/flutter/bin:$PATH"`.
- **PostgreSQL does not auto-start.** Start it each session before running the backend: `sudo pg_ctlcluster 16 main start`.
- **The backend requires env vars at import time or it will not boot:**
  - `GOOGLE_API_KEY` is read with `os.environ[...]` at import — the process crashes on startup if it is unset. For local dev without real AI calls, any non-empty placeholder works (e.g. `GOOGLE_API_KEY=dummy-key-for-local-dev`).
  - `DATABASE_URL` — the lifespan handler connects to Postgres on startup and there is **no mock/SQLite fallback** in the current `main.py` (the `USE_MOCK_DB` / `mock_db.py` path referenced in some older docs does not exist here). Use `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/ayma`.
  - `ADMIN_PASSWORD` — set it (e.g. `localadmin`) to use the password-gated `/admin/*` endpoints and the Flutter admin console.
- Run the backend: from `functions/bootstrap/`, activate `.venv`, export the vars above, then `uvicorn main:app --host 0.0.0.0 --port 8080`. Health check: `curl http://localhost:8080/health`.
- Run the frontend against the local backend: `cd ayma_flutter && flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8090 --dart-define=AYMA_BOOTSTRAP_URL=http://localhost:8080`. Backend CORS is `allow_origins=["*"]`, so the browser can call `localhost:8080` directly.

### Testing / validation without external credentials

- Backend logic tests are self-contained (they stub FastAPI, Firebase, Gemini, asyncpg): `functions/bootstrap/.venv/bin/python -m unittest functions/bootstrap/test_main_logic.py`.
- `flutter analyze` currently reports ~7 `info`-level deprecation notices (from the newer stable Flutter 3.44.4 SDK), with **0 errors and 0 warnings** — exit code is 0. These are SDK-version deprecations, not code defects.
- Most REST endpoints require a real Firebase ID token (`verify_token`) and Gemini API access, so full auth/chat/voice/matching E2E needs `GOOGLE_API_KEY` (Gemini) plus a Firebase test account. The **`/admin` console** (password-gated, no Firebase login) is the best way to exercise the client → backend → Postgres path without those secrets.
