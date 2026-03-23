import 'package:flutter/foundation.dart';

class Env {
  Env._();
  static const _wsUrlOverride =
      String.fromEnvironment('AYMA_WS_URL', defaultValue: '');
  static const _httpBaseUrlOverride =
      String.fromEnvironment('AYMA_HTTP_BASE_URL', defaultValue: '');

  // Web uses localhost; native devices need the LAN IP of the dev machine.
  // Override with:
  // flutter run --dart-define=AYMA_DEV_HOST=10.0.0.x
  static const _devHost =
      String.fromEnvironment('AYMA_DEV_HOST', defaultValue: '10.0.0.133');

  static String get wsUrl {
    if (_wsUrlOverride.isNotEmpty) return _wsUrlOverride;
    if (kIsWeb) return 'ws://localhost:8000/ws';
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Android debug builds use `adb reverse tcp:8000 tcp:8000`.
      return 'ws://127.0.0.1:8000/ws';
    }
    return 'ws://$_devHost:8000/ws';
  }

  static String get httpBaseUrl {
    if (_httpBaseUrlOverride.isNotEmpty) return _httpBaseUrlOverride;
    if (kIsWeb) return 'http://localhost:8000';
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://127.0.0.1:8000';
    }
    return 'http://$_devHost:8000';
  }
}
