# Manual Testing Guide

How to load the Flutter app against the production backend and test the core Ayma flows end to end.

---

## 0. Backend Data Layer

Ayma now uses **Cloud Firestore** for application data. PostgreSQL, `schema.sql`, `run_schema.py`, `cloud-sql-proxy`, and Cloud SQL start/stop steps are obsolete.

Cloud Run scales to zero automatically. Firestore, Firebase Storage, Gemini, LiveKit, and Firebase Functions are billed by usage, so there is no database instance to shut down after testing.

---

## 1. Install Dependencies

```bash
cd ayma_flutter
flutter pub get
./scripts/check-flutter-env
```

---

## 2. Use the Production Backend

Manual testing uses the deployed Cloud Run backend by default. Do not start local FastAPI unless you are debugging backend code.

```text
https://ayma-bootstrap-235381544962.us-central1.run.app
```

This URL is the production FastAPI service (`ayma-bootstrap`) running on Google Cloud Run in project `ayma-ai`, region `us-central1`. Firebase is still used for Auth, Firestore, and Storage; Cloud Run is the app's API/AI backend.

Cloud Run scales to zero by default when there is no traffic. As long as `min-instances` stays unset or `0`, this backend should not have Cloud Run CPU/memory charges while nobody is using the app. You can still see tiny usage-based costs from stored data/artifacts/logs or other services, but Gemini, LiveKit, Firestore reads/writes, and Cloud Run request compute are primarily incurred when the app or cron jobs actually call them.

### Verify Production Backend Is Up

```bash
curl https://ayma-bootstrap-235381544962.us-central1.run.app/health
# {"status":"ok"}
```

Authenticated endpoints require a Firebase ID token from the app.

---

## 3. Run the App on a Physical Phone

### 3a. Connect With Wireless ADB

The Pixel 10 Pro Fold is usually on local Wi-Fi at `10.0.0.203`, but the wireless debugging port changes.

```bash
adb mdns services
adb connect 10.0.0.203:<connect-port>
adb devices
```

If the device shows `offline` or the port changed after a reboot:

```bash
adb kill-server
adb start-server
adb pair 10.0.0.203:<pair-port> <6-digit-code>
adb connect 10.0.0.203:<connect-port>
```

The pair/connect ports come from Android Developer Options -> Wireless debugging.

### 3b. Run Against Production

```bash
cd ayma_flutter
flutter run -d <device-id>
```

No `AYMA_BOOTSTRAP_URL` override is needed. The app uses the production backend from `Env.bootstrapUrl`.

---

## 4. Run the App on the Android Emulator

### 4a. Check Emulator Is Running

```bash
flutter devices
```

If no emulator is running:

```bash
flutter emulators
flutter emulators --launch <emulator-id>
```

### 4b. Run Against Production

```bash
cd ayma_flutter
flutter run -d emulator-5554
```

### 4c. Build and Install APK Manually

Use this when `flutter run` exits early or you need to relaunch without the Flutter CLI attached:

```bash
cd ayma_flutter
flutter build apk --debug

adb -s emulator-5554 install -r \
  build/app/outputs/flutter-apk/app-debug.apk

adb -s emulator-5554 shell \
  am start -n com.ayma.ayma_flutter/.MainActivity
```

---

## 5. Smoke Validation Commands

Run these before or after a manual pass:

```bash
python3 -m unittest functions/bootstrap/test_main_logic.py
python3 -m py_compile functions/bootstrap/main.py
cd ayma_flutter && flutter analyze
```

Optional matching unit tests:

```bash
python3 -m unittest tests/unit/test_matching.py
```

---

## 6. Feature Checklist

Run through these after any significant code change.

### Auth and Onboarding

| Step | What to check |
|------|---------------|
| Auth | Email sign-in/sign-up works. Google, Apple, and phone sign-in buttons do not regress visually. |
| Welcome | New users see the onboarding welcome. Completed users are redirected to `/chat`. |
| Community select | 7 cards render: Western Dating, Indian Arranged Marriage, Muslim Matrimonial, West African Marriage, LGBTQ+ Dating, Find Your People, Cofounder & Collaborator. Selecting a card enables Continue. |
| About you | Name field, age slider, and gender chips work. Continue stays disabled until required fields are filled. |
| Preferences | Location permission request works. If denied, manual city entry and suggestions remain usable. Age range and interest controls persist. |
| Photos | Add photos button and Add photos later link are visible. Get started is available because photos are optional. |
| Submit | Get started completes onboarding and navigates to `/chat`, not back to onboarding. |

### Chat and Voice

| Check | Expected |
|-------|----------|
| Text message | Message appears immediately in the thread and sends over the LiveKit data channel after a room connection is established. |
| Connection failure | Banner shows "No connection" and says saved messages will be answered when Ayma is back online. |
| Quota failure | Banner shows "API quota reached" and says Ayma will reply when quota resets at midnight PT. |
| Voice session | Starting voice creates a LiveKit room via `/bootstrap`; the center Ayma tab pulses while connected. |
| Stop voice | Tapping the center Ayma tab while already on Chat and connected disconnects the session. |
| Photo in chat | Attached media uploads to Firebase Storage for chat context. It does not become profile media unless added through Profile. |
| Post-turn | After conversation turns, profile wiki/question answers update through `/post-turn`. |

### Shell Tabs

| Tab | Expected |
|-----|----------|
| Matches | Empty state says "Ayma is still getting to know you" for fresh profiles. Find matches now triggers `/run-matching`. |
| Explore | Profile cards render with search/filter controls. Opening a card shows the public profile and DM actions. |
| Ayma | Main chat surface with text input, attach button, and voice controls. |
| Signals | Empty state says "All caught up" for fresh profiles; unread badge appears when notifications exist. |
| You | Profile editor with public profile, private wiki, photos, completeness, and correction flow. |

### Secondary Screens

| Screen | Expected |
|--------|----------|
| Match detail | Shows score, rationale, both profile summaries, accept/reject controls, and vibe-check/simulation controls. |
| Direct messages | Opening a profile DM thread loads `/messages/{other_user_id}` and sends via `/messages`. |
| Settings | Available at `/settings`; includes matching pause, simulation transcript toggle, Ayma voice settings, privacy/export/delete actions, and logout. |
| Admin | `/admin` loads the admin dashboard. Data access requires `X-Admin-Password` for backend admin endpoints. |

---

## 7. ADB Quick Reference

```bash
# Screenshot to file
adb -s emulator-5554 exec-out screencap -p > /tmp/screen.png

# Dump UI tree
adb -s emulator-5554 shell uiautomator dump /data/local/tmp/ui.xml
adb -s emulator-5554 shell cat /data/local/tmp/ui.xml

# Tap at device coordinates
adb -s emulator-5554 shell input tap X Y

# Swipe up
adb -s emulator-5554 shell input swipe 540 1200 540 400 500

# Press BACK
adb -s emulator-5554 shell input keyevent 4

# Type text into a focused field
adb -s emulator-5554 shell input text "YourText"

# Flutter logs
adb -s emulator-5554 logcat -s flutter
```

`adb input text` is reliable for simple alphanumeric strings. For spaces, punctuation, emoji, and long text, use a real keyboard or paste through the emulator/device UI.

Project helpers:

```bash
./ayma_flutter/scripts/adb-ui devices
./ayma_flutter/scripts/adb-ui screenshot
./ayma_flutter/scripts/adb-ui dump
```

---

## 8. Deploy Backend to Cloud Run

```bash
cd functions/bootstrap
gcloud builds submit --tag gcr.io/ayma-ai/ayma-bootstrap .

ENV_VARS="GOOGLE_API_KEY=<key>,LIVE_MODEL=gemini-3.1-flash-live-preview,TEXT_MODEL=gemini-3.5-flash,LIVEKIT_URL=<url>,LIVEKIT_API_KEY=<key>,LIVEKIT_API_SECRET=<secret>"

gcloud run deploy ayma-bootstrap \
  --image gcr.io/ayma-ai/ayma-bootstrap \
  --region us-central1 \
  --service-account vertex-express@ayma-ai.iam.gserviceaccount.com \
  --set-env-vars "$ENV_VARS" \
  --allow-unauthenticated
```

Inspect the deployed revision and runtime env:

```bash
gcloud run revisions list --service ayma-bootstrap --region us-central1
gcloud run services describe ayma-bootstrap \
  --region us-central1 \
  --format="yaml(spec.template.spec.containers[0].env)"
```

---

## 9. Deploy Firebase Rules and Triggers

After editing `storage.rules` or `functions/triggers`:

```bash
firebase deploy --only storage,functions
```

Storage-only deploy:

```bash
firebase deploy --only storage
```

Daily matching cron setup lives in [cloud-scheduler.md](/home/suhailps/latest_claude/ayma/docs/cloud-scheduler.md).

---

## 10. Optional Local Backend Debugging

Only use this section when you are actively changing backend code and want the app to call your local FastAPI process. Normal manual testing should use production.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r functions/bootstrap/requirements.txt

export GOOGLE_API_KEY="your-gemini-key"
export FIREBASE_PROJECT_ID="ayma-ai"
export LIVEKIT_URL="wss://your-livekit-host"
export LIVEKIT_API_KEY="your-livekit-api-key"
export LIVEKIT_API_SECRET="your-livekit-api-secret"

cd functions/bootstrap
uvicorn main:app --host 0.0.0.0 --port 8080
```

Phone on same Wi-Fi:

```bash
cd ayma_flutter
flutter run -d <device-id> \
  --dart-define=AYMA_BOOTSTRAP_URL=http://192.168.X.X:8080
```

Emulator:

```bash
cd ayma_flutter
flutter run -d emulator-5554 \
  --dart-define=AYMA_BOOTSTRAP_URL=http://10.0.2.2:8080
```
