# Manual Testing Guide

How to bring up the backend, load the app on a device, and test all features end to end.

---

## 1. Install dependencies (once)

```bash
pip install asyncpg google-generativeai fastapi uvicorn firebase-admin \
  --break-system-packages
```

---

## 2. Start the backend

### Option A — Mock DB (no Postgres needed, fastest)

```bash
cd ayma/functions/bootstrap
USE_MOCK_DB=true uvicorn main:app --host 0.0.0.0 --port 8080
```

Data is in-memory only. Restarting the server wipes all profiles.

### Option B — Real Postgres (production-like)

Set up a local Postgres database and export connection details:

```bash
export DATABASE_URL="postgresql://user:pass@localhost:5432/ayma"
cd ayma/functions/bootstrap
uvicorn main:app --host 0.0.0.0 --port 8080
```

### Verify backend is up

```bash
curl http://localhost:8080/health
# → {"status":"ok"}
```

---

## 3. Load the app on a physical phone (Pixel)

### 3a. Connect via ADB Wi-Fi

The Pixel 10 Pro Fold is on the local network. From the project root:

```bash
adb connect 10.0.0.203:45309
adb devices   # should show 10.0.0.203:45309 device
```

If the port changes (after phone reboot), go to Developer Options → Wireless debugging → pair with QR/code.

### 3b. Run against production Cloud Run backend (default)

```bash
cd ayma/ayma_flutter
flutter run -d 10.0.0.203:45309
```

The app will connect to `https://ayma-bootstrap-235381544962.us-central1.run.app`.

### 3c. Run against local backend

Your laptop's local IP (find with `ip addr` or `ifconfig`) must be reachable from the phone on the same Wi-Fi:

```bash
cd ayma/ayma_flutter
flutter run -d 10.0.0.203:45309 \
  --dart-define=AYMA_BOOTSTRAP_URL=http://192.168.X.X:8080
```

Replace `192.168.X.X` with your actual LAN IP.

---

## 4. Load the app on the Android emulator

### 4a. Check emulator is running

```bash
flutter devices
# should list: sdk gphone64 x86 64 (emulator-5554)
```

If not running, start it:

```bash
flutter emulators --launch Medium_Phone_API_36.0
```

### 4b. Run against local backend

The emulator reaches the host machine at `10.0.2.2`:

```bash
cd ayma/ayma_flutter
flutter run -d emulator-5554 \
  --dart-define=AYMA_BOOTSTRAP_URL=http://10.0.2.2:8080
```

### 4c. Build and install APK manually

Use this when `flutter run` exits prematurely in background mode:

```bash
cd ayma/ayma_flutter
flutter build apk --debug \
  --dart-define=AYMA_BOOTSTRAP_URL=http://10.0.2.2:8080

adb -s emulator-5554 install -r \
  build/app/outputs/flutter-apk/app-debug.apk

adb -s emulator-5554 shell \
  am start -n com.ayma.ayma_flutter/.MainActivity
```

---

## 5. Feature checklist

Run through these after any significant code change.

### Onboarding

| Step | What to check |
|------|---------------|
| Welcome (step 0) | Only shown on first sign-up. Re-login should skip directly to community select. |
| Community select (step 1) | 7 cards render including "Find Your People" 🤝 and "Cofounder & Collaborator" 🚀. Selecting a card enables Continue. |
| About you (step 2) | Name field, age slider, gender chips. Continue disabled until name + gender filled. |
| Preferences (step 3) | Tapping Next auto-requests GPS permission. Tap "Don't allow" → location text field expands with city suggestions. Age range slider + interest chips work. |
| Photos (step 4) | "Add photos" picker button + "Add photos later" skip link visible. "Get started" enabled immediately (photos optional). |
| Submit | Tapping "Get started" or skipping photos navigates to /chat, NOT back to onboarding. |

### Chat screen

| Check | Expected |
|-------|----------|
| SESSION timer | Not visible during text-only chat. Only appears during live voice (WebSocket active). |
| Send text message | Message appears in thread. |
| Reply failure (quota) | Amber banner: "API quota reached — Ayma will reply when quota resets". No fake reply message. |
| Photo in chat | Photo uploads to Firebase Storage for Gemini context. Does NOT appear in your profile media gallery. |

### Shell tabs

| Tab | Expected |
|-----|----------|
| Chat | Text input, voice button, conversation thread. |
| Matches | Empty state "Ayma is still getting to know you" for fresh profiles. |
| Explore | Profile cards + filter chips. |
| Signals | Empty state "All caught up" for fresh profiles. |
| Profile — Public | Profile card with community badge, bio, photos. |
| Profile — Private | 4 wiki sections: WHO YOU ARE, WHAT YOU'RE LOOKING FOR, YOUR LIFE RIGHT NOW, FOR MATCHING. Empty state shows "Nothing here yet — keep chatting with Ayma!" |
| Settings | Shows username and logout button. |

---

## 6. ADB quick reference

```bash
# Screenshot → file
adb -s emulator-5554 exec-out screencap -p > /tmp/screen.png

# Dump UI tree (use to find tap coordinates)
adb -s emulator-5554 shell uiautomator dump /data/local/tmp/ui.xml
adb -s emulator-5554 shell cat /data/local/tmp/ui.xml

# Tap at phone coordinates (not screenshot pixels)
# Scale factor ≈ 0.657: phone_x = screenshot_x / 0.657
adb -s emulator-5554 shell input tap X Y

# Swipe up (scroll down)
adb -s emulator-5554 shell input swipe 540 1200 540 400 500

# Press BACK
adb -s emulator-5554 shell input keyevent 4

# Type text (only works when a text field already has focus)
adb -s emulator-5554 shell input text "YourText"
```

> **Note:** `adb input text` works for simple alphanumeric strings when the field is already focused. For complex emoji or special characters, use a real keyboard.

---

## 7. Deploy backend to Cloud Run (when ready)

```bash
# Build and push Docker image
cd ayma/functions/bootstrap
gcloud builds submit --tag gcr.io/ayma-ai/ayma-bootstrap .

# Deploy
gcloud run deploy ayma-bootstrap \
  --image gcr.io/ayma-ai/ayma-bootstrap \
  --region us-central1 \
  --platform managed \
  --allow-unauthenticated \
  --set-env-vars DATABASE_URL=$DATABASE_URL,GEMINI_API_KEY=$GEMINI_API_KEY
```

Check the deployed revision:
```bash
gcloud run revisions list --service ayma-bootstrap --region us-central1
```

---

## 8. Deploy Firebase Storage rules

After editing `ayma/storage.rules`:

```bash
cd ayma
npx firebase-tools login   # only needed once
npx firebase-tools deploy --only storage --project ayma-ai
```
