# Ayma UI And Pipeline Test Plan

> Read `PLAN.md` first.
>
> This document is the executable UI/runtime test plan for agents.
> Use it when a runnable Flutter environment is available.
>
> Preferred tooling order:
> 1. `flutter-skill` tools if exposed in-session
> 2. `adb-ui` fallback at `./ayma_flutter/scripts/adb-ui`
> 3. raw `adb` commands only if neither of the above are available

---

## Goal

Prove that the current app build is production-ready enough for release by validating:

- auth and routing
- onboarding and profile persistence
- community-specific onboarding behavior
- chat text path
- live voice path
- backend bootstrap and post-turn pipeline
- profile/story/insights rendering
- explore, matches, notifications, and settings screens
- app state consistency after navigation, backgrounding, and reconnects

---

## Preflight

Run these first:

```bash
./ayma_flutter/scripts/check-flutter-env
python3 -m unittest functions/bootstrap/test_main_logic.py
python3 -m py_compile functions/bootstrap/main.py functions/bootstrap/test_main_logic.py
```

If Flutter is runnable:

```bash
cd ayma_flutter
flutter pub get
flutter analyze
flutter run -d <device-id>
```

If `flutter-skill` tools are not available, use:

```bash
./ayma_flutter/scripts/adb-ui devices
./ayma_flutter/scripts/adb-ui launch <device-id>
./ayma_flutter/scripts/adb-ui snapshot <device-id>
./ayma_flutter/scripts/adb-ui dump <device-id>
```

---

## Test Accounts

Prepare at least:

- `User A`: new account for full onboarding and chat
- `User B`: second onboarded account for explore/matches/direct message checks

Prefer clean accounts so onboarding and first-run routing can be verified honestly.

---

## Validation Rules

For every screen/flow:

1. Capture current UI state.
2. Drive the interaction.
3. Capture resulting UI state.
4. Verify visible UI behavior.
5. Verify backend/data side effect if applicable.
6. Record pass/fail in `ayma_flutter/testing-lessons.md`.

When a failure happens, classify it:

- `build/runtime`: app does not launch or hot reload fails
- `routing`: wrong screen or redirect loop
- `state`: provider/state mismatch or stale UI
- `backend`: request accepted but data not persisted or returned
- `pipeline`: data persisted but not reflected downstream in prompt/wiki/matches
- `device-only`: permission, audio, storage, backgrounding, overlay, or lifecycle issue

---

## Screen Coverage

### 1. Auth

Actions:

- Launch signed-out app.
- Verify redirect to `/auth`.
- Test sign up with a fresh account.
- Test sign in with an existing account.
- Test sign out and return to `/auth`.

Look for:

- no blank screen before auth
- no redirect loop between `/auth` and `/chat`
- auth errors are surfaced clearly
- signed-in state survives app restart

Pipeline checks:

- authenticated `/profile` fetch succeeds after login
- router guard respects auth state

Common failures:

- Firebase config drift
- provider alias mismatch in router
- stale auth session cache

### 2. Onboarding

Actions:

- Complete onboarding from first launch with a new user.
- Verify step order:
  - welcome
  - community selection
  - about you
  - preferences/location
- Select each community type across repeated runs if possible.

Look for:

- community selection screen is actually present
- continue button is disabled until required data is present
- location entry works manually and via detect flow
- final action routes to chat

Pipeline checks:

- profile contains:
  - `community_profile`
  - `age`
  - `gender`
  - `location_region`
  - `location_coords` when detected
  - `matching_prefs.age_min`
  - `matching_prefs.age_max`
- backend bootstrap should not immediately re-ask age/gender/location/preferred age range as missing

Common failures:

- stale installed build missing community step
- `location_coords` silently dropped
- onboarding complete flag not honored by router

### 3. Shell Navigation

Tabs to verify:

- Matches
- Explore
- Ayma
- Signals
- You

Actions:

- Tap each tab once from a signed-in onboarded state.
- Verify selected state updates.
- Return to Ayma tab after leaving it.

Look for:

- no dead tabs
- no route mismatch
- unread indicator on notifications behaves correctly
- connected voice session behavior on Ayma tab does not leak across tabs unexpectedly

### 4. Chat Screen

#### 4A. Initial State

Actions:

- Open chat on a fresh onboarded user before starting voice.

Look for:

- no auto-started live voice session
- transcript opens at latest content
- mic button is visible and actionable
- composer accepts text

#### 4B. Text Chat

Actions:

- Send two short text messages.
- Send one longer message with personal preferences.
- If media attachments are enabled, send an image and a video.

Look for:

- user message appears immediately
- assistant reply arrives
- transcript ordering stays correct
- composer clears after send
- attachment state is visible while uploading

Pipeline checks:

- `/bootstrap` and/or text fallback route succeeds
- `/post-turn` runs after turn completion
- profile/wiki memory updates later reflect what was said

Failure clues:

- message visible but no reply: text fallback/backend issue
- reply visible but no story update later: post-turn pipeline issue

#### 4C. Live Voice

Actions:

- Tap mic to connect.
- Speak a short greeting.
- Interrupt Ayma during playback.
- Mute/unmute.
- Leave app and return if overlay/background support is relevant.

Look for:

- connection state progression
- transcript includes user and AI turns
- partial AI text is preserved on interrupt
- no stuck `Connecting...` state on failure
- voice session disconnects cleanly when requested

Pipeline checks:

- live voice contributes to the same post-turn memory/wiki path as text
- background/overlay behavior does not lose transcript state

Common failures:

- permission denial not handled cleanly
- session state stuck after transport error
- voice turn visible but not persisted to wiki/profile updates

### 5. Profile / You

Actions:

- Open profile after onboarding.
- Verify public/private profile sections render.
- If editable fields are exposed, change one and save.
- Upload or reorder photo(s) if supported.

Look for:

- profile loads without placeholder-only state
- saved edits persist after screen reload
- photo list/order remains stable after refresh

Pipeline checks:

- `FirestoreService`/backend profile read-write contract stays consistent
- public/private data split matches expectations

### 6. Your Story / Insights

Actions:

- Open story/insights after a few text and voice turns.

Look for:

- about you
- what you're looking for
- context/right now
- public profile/story summary
- media section if attachments were sent

Pipeline checks:

- text and voice facts show up after post-turn processing
- community-specific information appears if discussed

Common failures:

- successful chat with no story updates
- old cached insights after refresh

### 7. Explore

Actions:

- Open Explore as an onboarded user.
- Apply filters if available.
- Open another user profile.

Look for:

- list loads
- filters update results
- public profile shape matches expected backend fields

Pipeline checks:

- only onboarded profiles appear
- public profile fields do not leak private-only data

### 8. Matches

Actions:

- Open Matches with at least two onboarded users in the system.
- Trigger matching if the UI exposes it.
- Open match detail if a match exists.

Look for:

- empty state is sensible when no matches exist
- created matches appear without UI corruption
- detail screen renders rationale and participant summaries

Pipeline checks:

- backend matching endpoint writes matches
- community profile and preferences influence match outcomes plausibly

### 9. Direct Messages

Actions:

- From Explore or a match, open direct message screen.
- Send a message.

Look for:

- message thread loads
- sent message persists after reopen

Pipeline checks:

- notification path triggers for recipient if implemented

### 10. Notifications / Signals

Actions:

- Open notifications.
- Mark one notification read if supported.
- Reload screen.

Look for:

- unread count updates
- read state persists

Pipeline checks:

- notifications shown belong to signed-in user only

### 11. Settings

Actions:

- Open settings.
- Verify no broken actions or placeholder crashes.
- Use sign out if present.

Look for:

- stable navigation back to auth after sign out
- no stale authenticated data visible post-logout

---

## Cross-Cutting Checks

### Routing

Verify these route guards:

- signed-out user cannot reach shell screens
- signed-in but not onboarded user is sent to onboarding
- onboarded user is not sent back to onboarding

### Persistence

Verify after app restart:

- auth state
- onboarding complete state
- profile fields
- story/wiki updates
- notifications read state

### Error Handling

Manually test at least once:

- offline state
- backend unavailable
- denied mic permission
- denied location permission
- denied photo/media permission

Look for:

- user-visible error state
- no indefinite spinners
- recovery path without app restart where possible

---

## Release Gate

Do not mark the app production ready until all of these are true:

- backend logic tests pass
- backend syntax checks pass
- `flutter analyze` passes
- current source is rebuilt and installed on emulator or device
- onboarding community step is visible in the runtime build
- one full user can:
  - sign up,
  - complete onboarding,
  - chat by text,
  - chat by voice,
  - see story/profile updates,
  - navigate all main tabs without error
- at least one second user exists to validate explore/matches/DM/notifications paths
- `testing-lessons.md` contains the runtime results from the latest build

---

## Reporting Template

Append results to `ayma_flutter/testing-lessons.md` using:

```md
### YYYY-MM-DD feature or screen
- Tested: exact flow driven
- Outcome: pass / fail
- Root cause (if fail): actual failure source
- Fix applied: what changed
- Lesson: what to verify next time
```
