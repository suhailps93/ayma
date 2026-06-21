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
schema.sql                      ← PostgreSQL DDL
ayma_flutter/lib/services/
  api_service.dart              ← data CRUD via HTTP
  backend_service.dart          ← AI pipeline calls
  audio_service.dart            ← voice session
ayma_flutter/lib/env.dart       ← Cloud Run URL override
```

---

## Architecture Rules

1. Gemini Live WebSocket is **direct from Flutter** — never proxy audio through Cloud Run.
2. All data goes through backend HTTP (`ApiService` / `BackendService`).
3. Firebase Auth + Storage; PostgreSQL for all application data.
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
  --set-env-vars GOOGLE_API_KEY=<key>,LIVE_MODEL=gemini-3.1-flash-live-preview,TEXT_MODEL=gemini-3.5-flash,DATABASE_URL=<postgres-url> \
  --allow-unauthenticated
```

Deploy Firebase Storage rules:

```bash
firebase deploy --only storage
```

Daily matching cron: see [`cloud-scheduler.md`](cloud-scheduler.md).

---

## Environment Variables (Cloud Run)

| Var | Purpose |
|---|---|
| `GOOGLE_API_KEY` | Gemini API |
| `DATABASE_URL` | PostgreSQL connection string |
| `LIVE_MODEL` | Voice model (default: `gemini-3.1-flash-live-preview`) |
| `TEXT_MODEL` | Text model (default: `gemini-3.5-flash`) |
| `CRON_SECRET` | Auth header for `/run-matching-cron` |

Full list with defaults: `functions/bootstrap/config.py`.

---

## Local Backend

```bash
export DATABASE_URL="postgresql://user:pass@localhost:5432/ayma"
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

- Community onboarding end-to-end validation
- Question catalog single-source-of-truth
- Multi-user matching smoke test
- Text/voice chat device testing
