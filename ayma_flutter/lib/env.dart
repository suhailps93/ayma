// Build-time config: Cloud Run URL, live AI provider (Gemini/OpenAI), and API keys.
class Env {
  Env._();

  // AI provider switch.
  // Override at build time:
  //   flutter run --dart-define=AYMA_LIVE_PROVIDER=gemini
  //   flutter run --dart-define=AYMA_OPENAI_API_KEY=sk-...
  static const _liveProvider =
      String.fromEnvironment('AYMA_LIVE_PROVIDER', defaultValue: 'gemini');

  static const _openAiApiKey =
      String.fromEnvironment('AYMA_OPENAI_API_KEY', defaultValue: '');

  static const _openAiRealtimeModel =
      String.fromEnvironment('AYMA_OPENAI_REALTIME_MODEL', defaultValue: '');

  static const _openAiTextModel =
      String.fromEnvironment('AYMA_OPENAI_TEXT_MODEL', defaultValue: '');

  static const _openAiVoice =
      String.fromEnvironment('AYMA_OPENAI_VOICE', defaultValue: '');

  // Cloud Run bootstrap URL.
  // Override at build time:  flutter run --dart-define=AYMA_BOOTSTRAP_URL=https://...
  static const _bootstrapUrlOverride =
      String.fromEnvironment('AYMA_BOOTSTRAP_URL', defaultValue: '');

  static const _debugAudioDumpEnabled =
      bool.fromEnvironment('AYMA_DEBUG_AUDIO_DUMP', defaultValue: false);

  static const _adminUidsRaw =
      String.fromEnvironment('AYMA_ADMIN_UIDS', defaultValue: '');

  static String get bootstrapUrl {
    if (_bootstrapUrlOverride.isNotEmpty) return _bootstrapUrlOverride;
    return 'https://ayma-bootstrap-235381544962.us-central1.run.app';
  }

  static String get liveProvider => _liveProvider.trim().toLowerCase();

  static String get openAiApiKey {
    final key = _openAiApiKey.trim();
    if ((key.startsWith("'") && key.endsWith("'")) ||
        (key.startsWith('"') && key.endsWith('"'))) {
      return key.substring(1, key.length - 1).trim();
    }
    return key;
  }
  static String get openAiRealtimeModel => _openAiRealtimeModel.trim();
  static String get openAiTextModel => _openAiTextModel.trim();
  static String get openAiVoice => _openAiVoice.trim();
  static bool get debugAudioDumpEnabled => _debugAudioDumpEnabled;

  static List<String> get adminUids => _adminUidsRaw
      .split(',')
      .map((uid) => uid.trim())
      .where((uid) => uid.isNotEmpty)
      .toList(growable: false);

  static bool isAdminUid(String? uid) {
    final normalized = uid?.trim() ?? '';
    return normalized.isNotEmpty && adminUids.contains(normalized);
  }
}
