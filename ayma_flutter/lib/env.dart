class Env {
  Env._();

  // Cloud Run bootstrap URL.
  // Override at build time:  flutter run --dart-define=AYMA_BOOTSTRAP_URL=https://...
  static const _bootstrapUrlOverride =
      String.fromEnvironment('AYMA_BOOTSTRAP_URL', defaultValue: '');

  static const _debugAudioDumpEnabled =
      bool.fromEnvironment('AYMA_DEBUG_AUDIO_DUMP', defaultValue: false);

  static String get bootstrapUrl {
    if (_bootstrapUrlOverride.isNotEmpty) return _bootstrapUrlOverride;
    return 'https://ayma-bootstrap-235381544962.us-central1.run.app';
  }

  static bool get debugAudioDumpEnabled => _debugAudioDumpEnabled;
}
