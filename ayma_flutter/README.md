# Ayma Flutter App

> Read [`../PLAN.md`](../PLAN.md) first. Full architecture: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

Mobile client for Ayma. Thin presentation layer — all data and business logic go through Cloud Run (`ApiService` / `BackendService`). Firebase provides Auth and photo Storage only.

| Layer | Technology |
|---|---|
| UI / state | Flutter, Riverpod, go_router |
| Voice AI | Gemini Live WebSocket (direct from client) |
| Text AI | Gemini REST (client or server via `/chat/text`) |
| Auth | Firebase Auth → JWT for backend |
| Data | PostgreSQL via Cloud Run HTTP |
| Photos | Firebase Storage |

## Key paths

```
lib/
  main.dart, router.dart, env.dart, theme.dart
  models/       profile, match, community_profile, notifications
  providers/    Riverpod state
  services/     api_service, backend_service, audio_service, auth_service
  screens/      auth, onboarding, chat, matches, explore, profile, settings
  widgets/      ayma_button, ayma_text_field, public_profile_view
scripts/        check-flutter-env, adb-ui, adb-ts
```

## Run

```bash
flutter pub get
flutter run
# override backend: flutter run --dart-define=AYMA_BOOTSTRAP_URL=http://...
```

Default backend URL is in `lib/env.dart`.
