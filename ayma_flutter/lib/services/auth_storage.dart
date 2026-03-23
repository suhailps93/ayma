import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/auth_session.dart';

class AuthStorage {
  AuthStorage._();

  static const _storageKey = 'ayma.auth.session';
  static AuthSession? _session;

  static AuthSession? get session => _session;
  static String? get accessToken => _session?.accessToken;
  static String? get refreshToken => _session?.refreshToken;

  static Future<AuthSession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      _session = null;
      return null;
    }

    try {
      _session = AuthSession.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await prefs.remove(_storageKey);
      _session = null;
    }
    return _session;
  }

  static Future<void> save(AuthSession? session) async {
    final prefs = await SharedPreferences.getInstance();
    _session = session;
    if (session == null) {
      await prefs.remove(_storageKey);
      return;
    }
    await prefs.setString(_storageKey, jsonEncode(session.toMap()));
  }
}
