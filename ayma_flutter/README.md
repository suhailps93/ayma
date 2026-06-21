# Ayma — Flutter App

> Read `/home/suhailps/latest_claude/ayma/PLAN.md` first for the current branch plan, validation state, and handoff notes.
> This README describes the Flutter app structure, but it is not the canonical execution plan.

Ayma is an AI-first dating app where your personal AI companion (Ayma) learns who you are through voice and text conversations, curates matches for you, and handles all the introductions on your behalf.

## Architecture

| Layer | Technology |
|---|---|
| Frontend | Flutter (Dart), Riverpod, go_router |
| AI voice | Gemini Live API (WebSocket, PCM16 audio) |
| AI text | Gemini 2.5 Flash (REST, chat history) |
| Auth | Firebase Auth |
| Database | Cloud Firestore |
| Storage | Firebase Storage |
| Backend | Cloud Run (FastAPI) — bootstrap, post-turn memory, matching |

## Project Structure

```
lib/
  screens/
    auth/           — sign in / sign up
    chat/           — main voice + text chat with Ayma
    explore/        — browse profiles, direct messages
    insights/       — Ayma's wiki pages about you (Your Story)
    matches/        — curated introductions from Ayma
    notifications/  — signals (new matches, profile suggestions)
    onboarding/     — first-run preboarding flow
    profile/        — public + private profile editor
    settings/       — account, privacy, preferences
    shell/          — bottom tab navigation shell
  services/
    audio_service.dart    — Gemini Live WebSocket + flutter_sound recorder/player
    auth_service.dart     — Firebase Auth wrapper
    backend_service.dart  — Cloud Run API client
    api_service.dart      — backend HTTP client (profile, matches, notifs, explore, insights)
    web_audio_impl.dart   — Web mic/player (dart:html)
    web_audio_stub.dart   — Stub for non-web builds
  models/           — UserProfile, MatchModel, NotificationModel, AuthSession
  providers/        — Riverpod providers (auth, profile, matches, audio, explore)
  widgets/          — AymaButton, AymaTextField
  theme.dart        — AymaColors, AymaFonts, AymaTheme, HudPanel
  router.dart       — go_router config with auth + onboarding guards
  main.dart
  env.dart          — Cloud Run URL config
```

## Voice Chat

The chat screen connects to Gemini Live over WebSocket. PCM16 audio is streamed from the device microphone at 16 kHz; Gemini's audio responses are played back at 24 kHz. The waveform in the input pill is driven by real-time PCM-RMS amplitude (not a random animation).

- `SessionState`: disconnected → connecting → ready → listening ↔ thinking ↔ speaking
- Barge-in: user can interrupt Ayma mid-sentence; server sends `interrupted` event
- Text fallback: if live session is not active, messages go through Gemini 2.5 Flash REST API with full transcript history

## Wireless ADB Debugging (Tailscale)

```bash
# Connect ADB over Tailscale (port changes on every toggle)
./scripts/adb-ts <port>

# Run on device
flutter run -d 100.126.187.19:<port>
```

## Cloud Run Backend

Endpoints called by the app:
- `POST /bootstrap` — returns Gemini Live WebSocket URL, API key, system prompt
- `POST /post-turn` — saves conversation turn, triggers wiki update
- `POST /run-matching` — runs AI matching for the current user
