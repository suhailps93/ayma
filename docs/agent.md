# Ayma — Agent Operations Guide

> **Read [`PLAN.md`](../PLAN.md) first** for the execution checklist and handoffs.  
> **Read [`ARCHITECTURE.md`](ARCHITECTURE.md) first** for system design.  
> This file is ops-only: deploy commands, device setup, validation shortcuts.

---

## Quick Validation

```bash
python3 -m unittest functions/bootstrap/test_main_logic.py
python3 -m py_compile functions/bootstrap/main.py
./ayma_flutter/scripts/check-flutter-env
cd ayma_flutter && flutter analyze
```

Runtime test plans: [`ui_test_plan.md`](ui_test_plan.md), [`manual_testing_guide.md`](manual_testing_guide.md).

---

## Key Files

```
functions/bootstrap/main.py     ← all backend endpoints
functions/bootstrap/config.py   ← models, thresholds, rate limits (do not edit without PO approval)
functions/triggers/main.py      ← Firestore user-deletion cascade trigger
ayma_flutter/lib/services/
  api_service.dart              ← data CRUD via HTTP
  backend_service.dart          ← AI pipeline calls
  audio_service.dart            ← voice session
ayma_flutter/lib/env.dart       ← Cloud Run URL override
```

---

## Architecture Rules

1. LiveKit voice/text routes through WebRTC — audio never proxies through Cloud Run.
2. All data goes through backend HTTP (`ApiService` / `BackendService`).
3. Firebase Auth + Storage + Firestore; backend uses `google-cloud-firestore` AsyncClient.
4. PII stripped before matching LLM calls.
5. `flutter analyze` must stay at 0 errors, 0 warnings.
6. `firebase_options.dart` is generated — never edit manually.

---

## Stale Code Scan

Before/after tasks, grep for obsolete references:

- `supabase`, `langchain`, `langgraph`, `mem0`, `FirestoreService`, `cloud_firestore`
- `gemini-2.0-flash-live-001` → use `gemini-3.1-flash-live-preview`
- `gemini-2.0-flash` → use `gemini-3.5-flash`
- Hardcoded `localhost:8080` → use `Env.bootstrapUrl`

---

## Wireless ADB (Pixel 10 Pro Fold)

Device IP: `10.0.0.203` on local WiFi.

```bash
# Pair (code expires in ~60s — get from phone Developer Options → Wireless debugging)
adb pair 10.0.0.203:<pair-port> <6-digit-code>

# Connect (port from mdns, different from pair port)
adb mdns services
adb connect 10.0.0.203:<connect-port>
adb devices

# Run app
cd ayma_flutter && flutter run
```

If device shows `offline`: `adb kill-server && adb start-server`, re-pair if TLS cert expired.

ADB UI fallback: `./ayma_flutter/scripts/adb-ui devices`

---

## Deploy Cloud Run

```bash
cd functions/bootstrap
gcloud builds submit --tag gcr.io/ayma-ai/ayma-bootstrap .
gcloud run deploy ayma-bootstrap \
  --image gcr.io/ayma-ai/ayma-bootstrap \
  --region us-central1 \
  --service-account vertex-express@ayma-ai.iam.gserviceaccount.com \
  --set-env-vars GOOGLE_API_KEY=<key>,LIVE_MODEL=gemini-3.1-flash-live-preview,TEXT_MODEL=gemini-3.5-flash,LIVEKIT_URL=<url>,LIVEKIT_API_KEY=<key>,LIVEKIT_API_SECRET=<secret> \
  --allow-unauthenticated
```

Deploy Firebase Storage rules and Functions triggers:

```bash
firebase deploy --only storage,functions
```

### App Check (local dev)

1. Run the app once on emulator/device — logcat prints a debug App Check token.
2. Firebase Console → App Check → Apps → register the debug token.
3. Backend stays in monitor mode (`APP_CHECK_ENFORCE` unset/false) until tokens flow reliably, then set `APP_CHECK_ENFORCE=true` on Cloud Run.

Daily matching cron: see [`cloud-scheduler.md`](cloud-scheduler.md).

---

## Environment Variables (Cloud Run)

| Var | Purpose |
|---|---|
| `GOOGLE_API_KEY` | Gemini API key used by the backend and LiveKit agent |
| `LIVEKIT_URL` | LiveKit Cloud websocket URL |
| `LIVEKIT_API_KEY` | LiveKit server API key for dispatch and worker registration |
| `LIVEKIT_API_SECRET` | LiveKit server API secret for dispatch and worker registration |
| `LIVE_MODEL` | Voice model (default: `gemini-3.1-flash-live-preview`) |
| `TEXT_MODEL` | Text model (default: `gemini-3.5-flash`) |
| `CRON_SECRET` | Auth header for `/run-matching-cron` |
| `FIREBASE_PROJECT_ID` | GCP project (default: `ayma-ai`) |
| `APP_CHECK_ENFORCE` | When `true`, reject requests missing/invalid `X-Firebase-AppCheck` (default: monitor-only) |

Source of truth:
- Runtime secrets and runtime overrides are stored on the Cloud Run service under `spec.template.spec.containers[0].env`.
- `functions/bootstrap/config.py` only defines required env names and non-secret fallback defaults. Secrets are not stored in source.

Inspect current runtime env:

```bash
gcloud run services describe ayma-bootstrap \
  --region us-central1 \
  --format="yaml(spec.template.spec.containers[0].env)"
```

---

## Local Backend

```bash
export GOOGLE_API_KEY="your-key"
cd functions/bootstrap
uvicorn main:app --host 0.0.0.0 --port 8080

curl http://localhost:8080/health   # → {"status":"ok"}
```

Point Flutter at local backend:

```bash
flutter run --dart-define=AYMA_BOOTSTRAP_URL=http://10.0.0.203:8080
# or adb reverse tcp:8080 tcp:8080 for USB/wireless port forwarding
```

---

## Active Work

See [`PLAN.md`](../PLAN.md) for the live checklist. Current focus areas:

- Deploy Firestore-backed backend and smoke-test endpoints
- Deploy `functions/triggers` Firebase codebase
- Rebuild `/explore` search with structured Firestore filters (Step 4)
- Multi-user matching smoke test
- Text/voice chat device testing
