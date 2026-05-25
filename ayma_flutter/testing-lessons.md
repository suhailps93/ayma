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
