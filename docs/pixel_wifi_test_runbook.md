# Ayma Local Test Runbook For Pixel Over Wi‑Fi

> Read `PLAN.md` first.
>
> Status: this runbook is not the canonical plan. It contains older local-backend assumptions and must be used only together with the current validation/blocker state in `PLAN.md`.
>
> Current known issue from the latest agent run:
> - emulator/device execution was not completed from the Codex shell because Flutter is not on `PATH` there and the Android emulator binary failed to resolve `libX11.so.6`.
> - before using this runbook, verify that your shell can run both `flutter` and the Android emulator successfully.

This runbook is the repeatable setup for testing Ayma locally on a Pixel device over wireless ADB.

It covers:

- pairing and connecting a Pixel over Wi‑Fi
- running the local backend
- installing the Flutter app
- routing the phone to the local backend with `adb reverse`
- validating auth, live voice, text fallback, media upload, wiki, matches, and notifications

This assumes the repo lives at:

```bash
/home/suhailps/latest_claude/ayma
```

## 1. Prerequisites

You should already have:

- Android platform tools installed and `adb` available in your shell
- Flutter installed
- the Python runtime needed for any local backend checks you plan to run
- Flutter installed and runnable from your current shell
- the Android emulator or wireless ADB device connection working from your current shell
- any environment variables needed by the active backend flow

If you added new schema recently, apply migrations before testing.

## 2. Pair The Pixel Over Wi‑Fi

On the phone:

1. Open `Settings`
2. Open `Developer options`
3. Open `Wireless debugging`
4. Turn it on
5. Tap `Pair device with pairing code`

You will see:

- an `IP:pairing_port`
- a pairing code

On your machine, run:

```bash
adb pair PHONE_IP:PAIRING_PORT
```

Enter the pairing code when prompted.

Example:

```bash
adb pair 10.0.0.203:38393
```

After pairing, back on the phone’s `Wireless debugging` screen, note the normal connect address shown for the device.

Then connect:

```bash
adb connect PHONE_IP:CONNECT_PORT
adb devices
```

You want the output to show the phone as `device`, not `offline`.

Example:

```bash
adb connect 10.0.0.203:44313
adb devices
```

## 3. Start The Backend You Intend To Test

The active branch may be using the deployed bootstrap backend or the local `functions/bootstrap` service with SQLite fallback.
Do not assume the older monolithic local backend path below is still the active one for the branch you are testing.

Check `PLAN.md` first and confirm which backend path is current.

### Legacy local backend flow

Open a terminal and run:

```bash
cd /home/suhailps/latest_claude/ayma
./.venv/bin/python -m app.app_utils.expose_app --mode local --host 0.0.0.0 --port 8000
```

Leave that terminal open.

You should see lines like:

```text
Starting server in LOCAL mode
INFO:     Uvicorn running on http://0.0.0.0:8000
```

## 4. Route The Phone To The Local Backend

In a second terminal, run:

```bash
adb reverse tcp:8000 tcp:8000
```

This makes `127.0.0.1:8000` on the phone point to your laptop’s local backend.

You only need to rerun this if:

- the phone reconnects
- `adb` restarts
- the device drops off Wi‑Fi debugging

## 5. Build And Install The App

From the Flutter app directory:

```bash
cd /home/suhailps/latest_claude/ayma/ayma_flutter
flutter build apk --debug --no-pub
```

Install it:

```bash
adb install -r /home/suhailps/latest_claude/ayma/ayma_flutter/build/app/outputs/flutter-apk/app-debug.apk
```

Or use Flutter install directly:

```bash
cd /home/suhailps/latest_claude/ayma/ayma_flutter
flutter install
```

## 6. Launch The App

```bash
adb shell am start -S -n com.ayma.ayma_flutter/.MainActivity
```

The app should open on the phone.

## 7. Recommended Test Order

Use this order so you catch infrastructure problems early.

### A. Auth Test

1. Open the app
2. Sign in or sign up
3. If signing up, confirm the email link and make sure it deep-links back into the app
4. Verify you reach the app instead of a dead browser redirect

What should work:

- login
- refresh token flow
- deep-link confirmation back to `ayma://auth/confirm`

### B. Onboarding Test

1. Complete onboarding
2. Set name, age, gender, interested-in, age range, and location
3. Finish onboarding
4. Verify you land in chat

What should happen:

- `/api/onboarding` writes to `user_profiles`
- match generation is scheduled server-side

### C. Text Chat Test

1. In chat, do not start live voice yet
2. Send a short text message
3. Send another message
4. Upload an image and send text with it
5. Upload a video and send text with it

What should happen:

- text fallback route `/api/chat/text` replies
- image attachments are understood in the text path
- video attachments are understood in the text path if the backend can load the uploaded file
- media uploads return successfully
- processed media should start appearing in the user wiki / insights

### D. Live Voice Test

1. Start live voice
2. Say `hello`
3. Wait for the reply
4. Say one more short phrase
5. Wait idle for a while

What should happen:

- websocket connects
- Gemini Live replies with audio
- transcript shows full user and AI turns
- live turns feed the same post-turn memory pipeline as text turns
- if the session drops, reconnect behavior should be observable

### E. Wiki / Insights Test

1. Go to profile
2. Open `Your Story`
3. Verify these sections start filling in:
   - About You
   - What You’re Looking For
   - Right Now
   - Media

What should happen:

- text and live turns should both contribute to wiki updates
- uploaded images and videos should appear in `media.md` summaries

### F. Matches Test

1. Ensure there are at least two onboarded users in the system
2. Complete onboarding for both
3. Update profile text for one or both if needed
4. Open the matches screen

What should happen:

- server-side matching runs in the cloud/backend, not on the client
- `matches` table gets rows
- notifications for new matches should appear
- the matches screen should load those rows from `/api/matches`

### G. Notifications Test

1. Trigger a new match or profile suggestion
2. Open the notifications screen
3. Mark one read
4. Mark all read
5. Restart the app

What should happen:

- notifications persist because they are now backend-backed
- read state persists after restart

## 8. Useful Logs

### Backend Logs

Just watch the terminal where you started the backend.

Common things to watch for:

- `/ws` accepted
- `[live]` lines from `app/live_bridge.py`
- `/api/chat/text`
- `/internal/wiki-update`
- `/internal/update-profile`
- `/internal/memory-write`
- `/internal/generate-matches`
- `/internal/process-photo`

### Phone / Flutter Logs

Filter logcat like this:

```bash
adb logcat -d | rg "\[ws\]|\[audio\]|flutter|E/flutter|I/flutter|D/flutter|SessionState|setupComplete|remote disconnect|connection failure" -i | tail -250
```

If you want to stream instead of dumping:

```bash
adb logcat | rg "\[ws\]|\[audio\]|flutter|SessionState|setupComplete|remote disconnect|connection failure" -i
```

## 9. Common Recovery Steps

### If `adb devices` shows `offline`

Reconnect wireless ADB:

```bash
adb reconnect offline
adb connect PHONE_IP:CONNECT_PORT
adb devices
```

If needed, toggle `Wireless debugging` off and on again on the phone and reconnect.

### If the phone cannot reach the backend

Re-run:

```bash
adb reverse tcp:8000 tcp:8000
```

Then relaunch the app.

### If the backend port is already busy

Find and stop the old process, then restart the backend:

```bash
fuser -k 8000/tcp
cd /home/suhailps/latest_claude/ayma
./.venv/bin/python -m app.app_utils.expose_app --mode local --host 0.0.0.0 --port 8000
```

### If the app is stale after code changes

Rebuild and reinstall:

```bash
cd /home/suhailps/latest_claude/ayma/ayma_flutter
flutter build apk --debug --no-pub
adb install -r /home/suhailps/latest_claude/ayma/ayma_flutter/build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -S -n com.ayma.ayma_flutter/.MainActivity
```

## 10. Full Reusable Command Sequence

If everything is already paired and your phone is reachable, this is the shortest repeatable path:

```bash
cd /home/suhailps/latest_claude/ayma
./.venv/bin/python -m app.app_utils.expose_app --mode local --host 0.0.0.0 --port 8000
```

In another terminal:

```bash
adb connect PHONE_IP:CONNECT_PORT
adb reverse tcp:8000 tcp:8000
cd /home/suhailps/latest_claude/ayma/ayma_flutter
flutter build apk --debug --no-pub
adb install -r /home/suhailps/latest_claude/ayma/ayma_flutter/build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -S -n com.ayma.ayma_flutter/.MainActivity
```

## 11. What To Verify Before Calling It Good

A full local test pass should confirm all of these:

- auth works
- deep-link email confirmation works
- onboarding writes and completes
- text chat works
- live voice works for at least multiple turns
- live voice contributes to memory/wiki updates
- image upload is processed and appears in insights
- video upload is processed into a caption and appears in insights
- matches are generated server-side
- notifications persist and can be marked read
- pause matching blocks a user from new candidate generation
- delete account removes the user successfully

## 12. Notes

- The matching pipeline is backend-only. The client only reads results.
- If you are testing new backend schema, run migrations first.
- If you are testing cloud tasks in production-like mode, make sure `CLOUD_TASKS_QUEUE` and `BACKEND_URL` are correct.
- In local mode, several background tasks run inline or are scheduled from the backend without the client needing to know.
