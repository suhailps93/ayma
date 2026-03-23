import 'package:flutter/foundation.dart';

import '../models/auth_session.dart';
import 'auth_storage.dart';
import 'backend_service.dart';

class AuthService extends ChangeNotifier {
  AuthService() : _session = AuthStorage.session {
    _restore();
  }

  AuthSession? _session;
  bool _initialized = false;

  AuthSession? get session => _session;
  AuthUser? get currentUser => _session?.user;
  bool get initialized => _initialized;

  Future<void> _restore() async {
    _session = await AuthStorage.load();
    _initialized = true;
    notifyListeners();

    if (_session == null) {
      return;
    }

    try {
      final response = await BackendService.get(
        '/api/auth/session',
      ) as Map<String, dynamic>;
      final user = AuthUser.fromMap(response['user'] as Map<String, dynamic>);
      _session = _session!.copyWith(user: user);
      await AuthStorage.save(_session);
      notifyListeners();
    } catch (_) {
      final refreshed = await BackendService.refreshAuthToken();
      if (!refreshed) {
        await clearSession();
      } else {
        _session = AuthStorage.session;
        notifyListeners();
      }
    }
  }

  Future<bool> signIn(String email, String password) async {
    final response = await BackendService.post(
      '/api/auth/login',
      {
        'email': email,
        'password': password,
      },
      requiresAuth: false,
    ) as Map<String, dynamic>;
    return _applySessionResponse(response);
  }

  Future<bool> signUp(String email, String password) async {
    final response = await BackendService.post(
      '/api/auth/signup',
      {
        'email': email,
        'password': password,
      },
      requiresAuth: false,
    ) as Map<String, dynamic>;
    return _applySessionResponse(response);
  }

  Future<void> signOut() async {
    try {
      await BackendService.post('/api/auth/logout', const {});
    } catch (_) {
      // Local session still needs to be cleared even if remote logout fails.
    }
    await clearSession();
  }

  Future<void> clearSession() async {
    _session = null;
    await AuthStorage.save(null);
    notifyListeners();
  }

  bool _applySessionResponse(Map<String, dynamic> response) {
    final sessionMap = response['session'] as Map<String, dynamic>?;
    if (sessionMap == null) {
      return false;
    }
    _session = AuthSession.fromMap(sessionMap);
    AuthStorage.save(_session);
    notifyListeners();
    return true;
  }
}
