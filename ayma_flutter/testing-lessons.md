# Flutter Testing Lessons

This file is the persistent test memory. The test sub-agent reads it before every test run
and appends to it after every test run. Never truncate or rewrite — always append.

## Format

Each entry:
```
### [DATE] [SCREEN/FEATURE]
- Tested: what interaction was driven
- Outcome: pass / fail
- Root cause (if fail): what was actually wrong
- Fix applied: what agent was called, what changed
- Lesson: what to check for next time
```

---

## Entries

<!-- Test sub-agent appends below this line -->
### 2026-05-24 profile page refresh
- Tested: flutter analyze on `lib/screens/profile/profile_screen.dart` and `lib/providers/providers.dart`
- Outcome: pass
- Root cause (if fail): n/a
- Fix applied: updated `ProfileScreen` to use the same public-profile snapshot and insights sources as Explore/Insights; added a public profile provider and invalidation on save/upload
- Lesson: keep the self profile and viewed profile paths on the same Firestore data shape so gallery/story refresh together
### 2026-05-25 live voice echo loop prevention
- Tested: static verification with `flutter analyze` on `lib/services/audio_service.dart` and `lib/services/web_audio_impl.dart`
- Outcome: pass (static), pending runtime UI/audio verification
- Root cause (if fail): prior web path sent mic continuously without real voice activity gating, allowing model playback to re-enter capture path
- Fix applied: Codex patched local VAD-based mic gating in audio service + web zero-gain processor routing + stronger browser audio constraints for echo suppression
- Lesson: for Gemini Live duplex audio, combine platform AEC with local speech-aware send gating during model speech to prevent self-loop
### 2026-05-25 websocket duplex simplification (Gemini Live)
- Tested: static verification with `flutter analyze` after simplifying websocket message handling and keeping duplex audio path
- Outcome: pass (static), runtime hot-reload/audio interaction pending
- Root cause (if fail): overly complex ws filtering/debug branches obscured core Live message flow and made behavior harder to reason about
- Fix applied: reduced to basic Live flow (setupComplete, realtimeInput audio send, modelTurn audio receive, interrupted/turnComplete handling) while keeping anti-echo guard
- Lesson: keep Live socket handlers close to API reference unions and avoid speculative filtering branches
### 2026-05-25 rollback websocket live path to pre-2026-05-24 baseline
- Tested: restored `lib/services/audio_service.dart` and `lib/services/web_audio_impl.dart` from commit `ac9b376` and ran `flutter analyze`
- Outcome: pass (static), runtime duplex audio verification pending
- Root cause (if fail): newer websocket/live changes introduced non-essential complexity versus previous known-working baseline
- Fix: git restore from `ac9b376` for websocket live/audio path files
- Lesson: keep Live websocket flow close to setup/setupComplete/realtimeInput/serverContent basics and validate runtime after each iteration
### 2026-05-25 full audio_service rewrite (minimal duplex + shared context + tool calls)
- Tested: `flutter analyze` on `lib/services/audio_service.dart` and `lib/services/web_audio_impl.dart` after full service rewrite
- Outcome: pass (static), runtime hot-reload duplex verification pending
- Root cause (if fail): prior service had accumulated reconnect/filter/history variants that made behavior harder to reason about for live duplex
- Fix: rewrote `audio_service.dart` to minimal architecture preserving UI API while keeping only core live websocket, shared history across live/text, and tool-call response path
- Lesson: lock service surface first (UI contract), then keep live socket logic minimal and explicit
### 2026-05-31 OpenAI Realtime 2 provider switch
- Tested: `flutter analyze`; direct OpenAI Realtime WebSocket session handshake; launched Chrome web run with `AYMA_LIVE_PROVIDER=openai`; captured auth-screen screenshot and accessibility tree through CDP after Flutter MCP transport closed
- Outcome: pass for static analysis, OpenAI `session.created`/`session.updated`, and startup render; Flutter MCP hot_reload/take_screenshot/get_accessibility_tree unavailable due transport closed; `flutter run` hot restart later stuck and was stopped
- Root cause (if fail): Flutter MCP server transport unavailable; web hot restart reported disposed service connection after manual stop
- Fix: Codex implemented OpenAI Realtime client, provider switch, OpenAI text fallback, 16 kHz to 24 kHz mic PCM resampling, and Realtime event compatibility aliases
- Lesson: when migrating live audio providers, verify sample-rate expectations and keep CDP fallback available if Flutter MCP transport is down
### 2026-05-31 Pixel phone OpenAI Realtime install
- Tested: wireless ADB install/run on Pixel 10 Pro Fold; real device screenshot; `uiautomator` accessibility tree; mic tap; hot reload/restart; OpenAI credential validation with `/v1/models/gpt-realtime-2`
- Outcome: app installed and authenticated chat rendered; mic path reached OpenAI but returned `invalid_api_key`; UI now returns to offline instead of staying stuck on `Connecting...`
- Root cause (if fail): supplied OpenAI key was rejected by OpenAI with HTTP 401 / `invalid_api_key`; native client also initially used an `https` URI for WebSocket before patch
- Fix: Codex changed Realtime URI to `wss`, added native Realtime headers/subprotocol, made OpenAI bootstrap optional when a local OpenAI key is supplied, and disconnects cleanly on Realtime error events
- Lesson: verify supplied OpenAI keys against a simple REST endpoint before live audio testing; Realtime auth errors must stop the mic recorder and reset UI state
### 2026-05-31 Pixel phone gpt-realtime-2 live voice
- Tested: validated OpenAI key against `/v1/models/gpt-realtime-2`; rebuilt Pixel 10 Pro Fold app with corrected dart-define JSON; mic-driven live voice session; screenshot; `flutter analyze`
- Outcome: pass; live session connected to `gpt-realtime-2`, user speech transcribed, Ayma spoke back through realtime audio, and hot reload worked
- Root cause (if fail): temp dart-define JSON had literal quote characters around the key, and OpenAI path was incorrectly using bootstrap `model` value `gemini-3.1-flash-live-preview`
- Fix: regenerated temp define JSON without extra quotes, stripped accidental quote wrappers in `Env.openAiApiKey`, ignored Gemini bootstrap model for OpenAI, and suppressed duplicate final transcript events
- Lesson: for provider-switch code, never reuse a provider-specific bootstrap model field across providers; verify compiled dart-defines for hidden quote characters before debugging auth
### 2026-06-18 onboarding community flow runtime verification
- Tested: inspected attached emulator `emulator-5554`, confirmed installed package `com.ayma.ayma_flutter`, dumped current onboarding accessibility tree, tapped through welcome screen to compare runtime UI against latest source
- Outcome: fail for latest-source verification; runtime install is stale and does not include the new community-selection step
- Root cause (if fail): current shell can access `adb` by full path, but Flutter CLI is not available on `PATH` and the emulator binary cannot be launched from this shell because `libX11.so.6` is not visible, so the updated app could not be rebuilt/reinstalled after code changes
- Fix applied: none to runtime environment in this turn; documented the blocker in `PLAN.md`, aligned agent docs to the canonical plan, and verified backend Python compile path instead
- Lesson: before trusting emulator smoke results, confirm the installed build actually reflects current source changes; if onboarding skips a newly added step, stop and rebuild from a shell with working `flutter` plus emulator/device runtime libraries
### 2026-06-18 onboarding submit regression on emulator-5554
- Tested: drove the current emulator build through welcome, community selection, about-you, and preferences; filled the name field via `adb shell input text`, selected gender and partner preference, and submitted onboarding with `Get started`
- Outcome: fail; submit returned to onboarding welcome instead of landing on chat
- Root cause (if fail): backend `/profile` endpoint only performed `UPDATE users ... WHERE id = $uid`; for a first-time user with no existing row, onboarding writes were silently dropped, so router refresh saw onboarding incomplete and redirected back to onboarding
- Fix applied: Codex patched `functions/bootstrap/main.py` to insert the user row before applying profile updates and added a regression test in `functions/bootstrap/test_main_logic.py`
- Lesson: for first-run flows, test against a truly new user and verify that write endpoints create prerequisite rows rather than assuming bootstrap/profile reads already ran
### 2026-06-19 full smoke pass on emulator-5554 after backend upsert fix and Cloud Run redeploy
- Tested: onboarding full flow (welcome → community selection → about you → preferences → submit); all main shell screens (Chat, Matches, Explore, Signals/Notifications, Profile Public, Profile Private, Settings); drove via coordinate-based adb taps; Cloud Run redeployed from patched source before submit
- Outcome: PASS for all screens; onboarding submit now lands on /chat (upsert fix confirmed in production); profile persisted (Settings shows "TestUser"); all screens render correct content or correct empty state
- Root cause (if fail): n/a — all pass
- Fix applied: restarted local uvicorn from patched main.py; built new Docker image (gcloud builds submit, 58s); deployed to Cloud Run revision 00013 (ayma-bootstrap-00013-hpv)
- Lesson: adb `input text` and `input keyevent` do NOT inject text into Flutter TextFields (Flutter owns its own IME); test text chat only via real device keyboard or flutter_driver; coordinate-based taps work for buttons/selections; screenshot-pixel-to-phone-pixel scale factor is needed (screenshot_width/phone_width ≈ 0.657 for this emulator config)
- Screens covered: welcome ✓, community-select ✓, about-you ✓, preferences ✓, onboarding-submit→chat ✓, matches empty-state ✓, explore search+filters ✓, signals empty-state ✓, profile-public ✓, profile-private ✓, settings-full ✓
### 2026-06-19 full feature smoke test — new community cards, GPS dialog, photos step, SESSION timer, wiki sections
- Tested: community selection cards (Find Your People, Cofounder & Collaborator); About You step (name via adb input text, gender, age); Preferences step (GPS permission dialog auto-trigger, deny→expand fallback, city suggestions, interest + age range); Photos step (Add photos, Get started, "Add photos later" skip link); onboarding submit via "Add photos later"; all 5 shell tabs (MATCHES, EXPLORE, AYMA, SIGNALS, YOU); Chat screen SESSION timer check; Profile Private wiki sections
- Outcome: ALL PASS except Onboarding Welcome step BLOCKED (preboardingSeen=true skips it in returning user flow)
- Root cause (if fail): Welcome step (code step 0, "Hi. I'm Ayma." with breathing orb) is auto-skipped when preboardingSeen=true; cannot verify it without a fresh account
- Fix applied: none — all other features pass
- Lesson 1: adb `input text` DOES work for Flutter TextFields when the field is first focused via `adb input tap` before calling `input text`. Previous lesson was overstated — the requirement is focus-first, not flutter_driver. Corrects earlier entry that said it never works.
- Lesson 2: Onboarding step numbering in code is 0=welcome, 1=community-select, 2=about-you, 3=preferences, 4=photos. Task docs may label them differently (e.g. "Step 1" for community-select). Use code comments as ground truth.
- Lesson 3: Location/city field is in Step 3 (Preferences), NOT Step 2 (About You). The Preferences step triggers _detectLocation() on entry which fires the Android GPS permission dialog automatically.
- Lesson 4: GPS permission dialog fires from permissioncontroller package — use uiautomator dump to get exact button bounds; the dialog overlays the app with package=com.google.android.permissioncontroller. "Don't allow" button correctly causes _locationExpanded=true, showing the text field with seed city suggestions.
- Lesson 5: Private profile wiki section names are "WHO YOU ARE", "WHAT YOU'RE LOOKING FOR", "YOUR LIFE RIGHT NOW", "FOR MATCHING" (not "About Me, Context, Preferences, FOR MATCHING" as some docs state). All 4 sections render; fresh profiles show "Nothing here yet — keep chatting with Ayma!" which is correct empty-state behavior.
- Lesson 6: SESSION timer is NOT present in the chat screen UI tree when in text/offline mode — confirmed via accessibility tree scan. Only the elements OFFLINE, "Say Hey Ayma to start", "Tonight's conversation", "Your conversation begins when you start speaking", and nav tabs are present.
- Lesson 7: Explore tab mock profiles show "$age" as the age field — this is unfilled mock data from mock_db.py seed, not a UI formatting bug.
- Screens covered: community-select (Find Your People ✓, Cofounder & Collaborator ✓), about-you (name text input ✓, gender ✓, age slider ✓), preferences (GPS dialog ✓, deny→expand ✓, city suggestions ✓, interest ✓, age range ✓), photos step (Add photos button ✓, Get started ✓, "Add photos later" skip ✓), onboarding-submit→chat ✓, matches empty-state ✓, explore profiles ✓, signals empty-state ✓, profile-private wiki sections ✓, chat no-SESSION-timer ✓
### 2026-06-19 web app smoke test (agent-browser)
- Tested: Flutter web at http://localhost:9090 — initial load, render check, overlay permission dialog, login screen all four auth buttons (Apple, Google, Email, Phone), Email form navigation, CORS fetch to http://localhost:8080/health
- Outcome: PASS for all core checks; one web-specific bug found (overlay permission dialog appears on web)
- Root cause (if fail): Flutter renders correctly via CanvasKit (WebGL + shadow DOM canvas); `main.dart.js` (3.8 MB) loaded from service worker cache; title changed to "Ayma" confirming Flutter init. Overlay bug: `ShellScreen.initState()` calls `OverlayService.isGranted()` (which calls `FlutterOverlayWindow.isPermissionGranted()`) without a `kIsWeb` guard — on web this returns `false` so `_showOverlayPermissionDialog()` fires, showing an Android-specific permission dialog to web users
- Fix applied: none yet — bug documented; fix requires adding `if (kIsWeb) return;` guard at the top of the `addPostFrameCallback` block in `lib/screens/shell/shell_screen.dart` line 33–37
- Lesson 1: Flutter CanvasKit web renders via WebGL canvas inside the shadow root of `flt-glass-pane`. Agent-browser `snapshot -i` only sees the semantics placeholder ("Enable accessibility" button) until Flutter's accessibility tree is populated. Use coordinate-based pointer events on `flutter-view` element to drive taps: dispatch `PointerEvent('pointerdown')` + `PointerEvent('pointerup')` on `document.querySelector('flutter-view')` — this is the only reliable tap method for CanvasKit web
- Lesson 2: Viewport is 1280x577 for agent-browser headless Chrome; use this to calibrate tap coordinates from screenshots. Button positions must be calculated from the 1280x577 canvas size
- Lesson 3: CORS check result: `fetch('http://localhost:8080/health')` returned `{"status":"ok"}` from inside the Flutter web app origin — CORS headers are correct
- Lesson 4: `performance.getEntriesByType('resource')` shows `transferSize: 0` for cross-origin resources (privacy-blocked) and for service-worker-cached resources; use `encodedBodySize > 0` to confirm a resource actually loaded
- Lesson 5: To interact with Flutter web buttons, the flutter-view must receive the pointer events. Canvas/document dispatch is insufficient — only `document.querySelector('flutter-view').dispatchEvent(new PointerEvent(...))` works
- Screenshots: /tmp/web_01_load.png (initial), /tmp/web_02_flutter.png (overlay dialog), /tmp/web_03_login.png (clean login screen), /tmp/web_07_flutter_view_click.png (dialog dismissed), /tmp/web_11_email_signin_form.png (email auth form)
- Screens covered: login/auth screen ✓, overlay permission dialog ✓ (fires on web — bug), Email form navigation ✓, CORS to backend ✓
### 2026-06-20 Gemini model fix + onboarding SharedPreferences cache
- Tested: Gemini WebSocket model name (gemini-2.0-flash-live-001 vs gemini-3.1-flash-live-preview) + onboarding SharedPreferences skip; device 10.0.0.203:43723 (Pixel phone); rebuilt debug APK from source and installed via adb install
- Outcome:
  - Fix 1 (Voice model): FAIL — runtime logs still show `"model":"models/gemini-3.1-flash-live-preview"` and `WebSocket closed (code: 1011)` reconnect loop. Root cause: the Flutter-side fallback in audio_service.dart (line 416/462) was updated to `gemini-2.0-flash-live-001`, but this fallback is only used when `setup == null`. The backend bootstrap server (`config.py` line 25: `LIVE_MODEL = os.environ.get("LIVE_MODEL", "gemini-3.1-flash-live-preview")`) returns a non-null `setup` including the old model name, which overrides the Flutter fallback. The backend config.py default needs to change for the Flutter fix to take effect.
  - Fix 2 (Onboarding SharedPreferences cache): PASS — screenshot confirmed app goes directly to `/chat` screen on relaunch, bypassing onboarding. `getOnboardingStatus()` in api_service.dart (line 320-323) returns true from SharedPreferences cache without a network round-trip.
- New failure patterns:
  - `gemini-3.1-flash-live-preview` model returns 1011 "Internal error encountered" consistently — may be model availability/key issue
  - flutter run -d <device> times out at 120s on this machine (build takes ~12s but full attach+install takes longer); use `flutter build apk --debug && adb install -r` instead for reliable CI installs
  - debugPrint logs (I/flutter : DEBUG:) only appear in logcat when voice is actively triggered (Gemini connect attempt); they do not appear on startup startup routing — route checks are silent
- Screens covered: chat screen direct navigation (onboarding skip) ✓; voice connect attempt logs ✓
