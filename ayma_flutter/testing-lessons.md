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
