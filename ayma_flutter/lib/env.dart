import 'package:flutter/foundation.dart';

class Env {
  Env._();
  static const _publicBaseUrlOverride =
      String.fromEnvironment('AYMA_PUBLIC_BASE_URL', defaultValue: '');
  static const _wsUrlOverride =
      String.fromEnvironment('AYMA_WS_URL', defaultValue: '');
  static const _httpBaseUrlOverride =
      String.fromEnvironment('AYMA_HTTP_BASE_URL', defaultValue: '');
  static const _debugAudioDumpEnabled =
      bool.fromEnvironment('AYMA_DEBUG_AUDIO_DUMP', defaultValue: false);

  // Web uses localhost; native devices need the LAN IP of the dev machine.
  // Override with:
  // flutter run --dart-define=AYMA_DEV_HOST=10.0.0.x
  static const _devHost =
      String.fromEnvironment('AYMA_DEV_HOST', defaultValue: '10.0.0.133');

  static Uri? get _publicBaseUri =>
      _publicBaseUrlOverride.isEmpty ? null : Uri.parse(_publicBaseUrlOverride);

  static String get wsUrl {
    if (_wsUrlOverride.isNotEmpty) return _wsUrlOverride;
    final publicBaseUri = _publicBaseUri;
    if (publicBaseUri != null) {
      final scheme = publicBaseUri.scheme == 'https' ? 'wss' : 'ws';
      return publicBaseUri
          .replace(
            scheme: scheme,
            path: '/ws',
            query: null,
            fragment: null,
          )
          .toString();
    }
    if (kIsWeb) return 'ws://localhost:8000/ws';
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Android debug builds use `adb reverse tcp:8000 tcp:8000`.
      return 'ws://127.0.0.1:8000/ws';
    }
    return 'ws://$_devHost:8000/ws';
  }

  static String get httpBaseUrl {
    if (_httpBaseUrlOverride.isNotEmpty) return _httpBaseUrlOverride;
    final publicBaseUri = _publicBaseUri;
    if (publicBaseUri != null) {
      return publicBaseUri
          .replace(path: '', query: null, fragment: null)
          .toString()
          .replaceFirst(RegExp(r'/$'), '');
    }
    if (kIsWeb) return 'http://localhost:8000';
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://127.0.0.1:8000';
    }
    return 'http://$_devHost:8000';
  }

  static bool get debugAudioDumpEnabled => _debugAudioDumpEnabled;
}
