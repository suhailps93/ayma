# Firebase Migration Plan

## Architecture After Migration

| Before | After |
|---|---|
| Supabase Auth | Firebase Auth |
| Supabase PostgreSQL | Firestore |
| GCS (photos) | Firebase Storage |
| Supabase Realtime / polling | Firestore real-time streams |
| FastAPI backend (full) | Cloud Run — single minimal function |
| Mem0 | Gemini fact extraction → Firestore |
| pgvector | Firestore (recent memories, semantic search later) |
| LangGraph / ADK | Deleted |
| React frontend | Deleted |

## Firestore Collections

```
users/{uid}
  display_name, profile_public, profile_private, profile_ai_observations
  agent_name, voice_preference, matching_prefs (map)
  age, gender, location_region, location_coords
  community_profile, onboarding_complete, matching_paused

users/{uid}/memories/{id}
  text, session_id, created_at

users/{uid}/skills/{id}
  name, content, enabled

matches/{id}
  user_a, user_b, score, commonalities, differences, rationale
  summary_a, summary_b, status, created_at, updated_at

notifications/{id}
  user_id, type, title, body, meta, read, created_at

media/{id}
  user_id, photo_url, caption, created_at
```

## Cloud Run Function Endpoints

| Endpoint | Purpose |
|---|---|
| `POST /bootstrap` | Verify Firebase ID token → build system prompt → return Gemini Live WS URL + key |
| `POST /post-turn` | Extract facts from turn with Gemini → store to Firestore memories |

Photo upload goes **directly** from Flutter → Firebase Storage (no backend needed).

## Progress

- [x] Write MIGRATION.md
- [x] Cloud Run function (`functions/bootstrap/`)
- [x] Flutter `pubspec.yaml` — add Firebase packages
- [x] Flutter `main.dart` — Firebase.initializeApp()
- [x] Flutter `env.dart` — Cloud Run URL
- [x] Flutter `firebase_options.dart` — template
- [x] Flutter `models/auth_session.dart` — simplified
- [x] Flutter `services/auth_service.dart` — Firebase Auth
- [x] Flutter `services/firestore_service.dart` — new
- [x] Flutter `services/backend_service.dart` — Cloud Run calls only
- [x] Flutter `providers/providers.dart` — Firestore-based
- [x] Flutter `router.dart` — Firebase auth state
- [x] Flutter `services/audio_service.dart` — Firebase token for bootstrap
- [x] Delete old backend code (`app/`, `frontend/`, `migrations/`, `ops/`)
- [x] `flutter analyze` — 0 errors, 0 warnings
- [x] User: Create Firebase project + run `flutterfire configure`
- [x] Deploy Cloud Run function → https://ayma-bootstrap-235381544962.us-central1.run.app
- [x] Gemini API key created and set in Cloud Run
- [x] Firestore security rules deployed
- [x] Firebase Storage rules deployed
- [x] `env.dart` updated with real Cloud Run URL
- [x] User: Run `flutter pub get` — 0 issues
- [ ] Test: auth flow (sign up → onboarding → chat)
- [ ] Test: voice session (bootstrap → Gemini Live connection)
- [ ] Test: memory (post-turn → Firestore write)
- [ ] Test: profile read/write via Firestore

## Setup Steps for User

### 1. Firebase Project
```bash
# Create project at console.firebase.google.com
# Enable: Authentication (email/password), Firestore, Storage, Messaging

# Install FlutterFire CLI
dart pub global activate flutterfire_cli

# Configure (run from ayma_flutter/)
flutterfire configure --project=YOUR_FIREBASE_PROJECT_ID
# This generates lib/firebase_options.dart — replace the template
```

### 2. Firestore Indexes
```bash
# Composite index for notifications
gcloud firestore indexes composite create \
  --collection-group=notifications \
  --field-config field-path=user_id,order=ASCENDING \
  --field-config field-path=created_at,order=DESCENDING

# Composite index for memories
gcloud firestore indexes composite create \
  --collection-group=memories \
  --field-config field-path=created_at,order=DESCENDING
```

### 3. Deploy Cloud Run Function
```bash
cd functions/bootstrap
gcloud run deploy ayma-bootstrap \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars GOOGLE_API_KEY=YOUR_KEY,LIVE_MODEL=gemini-3.1-flash-live-preview
```

### 4. Flutter
```bash
cd ayma_flutter
flutter pub get
flutter run --dart-define=AYMA_BOOTSTRAP_URL=https://YOUR_CLOUD_RUN_URL
```

## Security Note

The bootstrap endpoint returns the Gemini API key to authenticated clients. This is acceptable for internal apps but should be replaced with short-lived OAuth tokens (Vertex AI) before public release.

## Migration — 2026-06-19: FCM, rate limiting, structured logging

### Run on existing Postgres DB

```sql
-- Add FCM token column (safe to run multiple times)
ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token VARCHAR(512);
```

### New environment variables (Cloud Run)

```bash
gcloud run services update ayma-bootstrap --region=us-central1 \
  --update-env-vars="GOOGLE_API_KEY_BACKUP=<your-backup-key>,CRON_SECRET=<random-hex>"
```

### Firebase Storage rules (requires re-auth)

```bash
firebase login --reauth
firebase deploy --only storage --project ayma-ai
```

### Cloud Scheduler (one-time)

See `docs/cloud-scheduler.md` for setup instructions.
