import 'dart:convert';

import 'package:http/http.dart' as http;

import '../env.dart';
import '../models/auth_session.dart';
import 'auth_storage.dart';

class BackendService {
  BackendService._();

  static Uri _uri(String path, [Map<String, dynamic>? query]) => Uri.parse(
        '${Env.httpBaseUrl}$path',
      ).replace(
        queryParameters:
            query?.map((key, value) => MapEntry(key, value.toString())),
      );

  static Map<String, String> _headers({bool requiresAuth = true}) {
    final token = requiresAuth ? AuthStorage.accessToken : null;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<dynamic> get(
    String path, [
    Map<String, dynamic>? query,
    bool requiresAuth = true,
  ]) async {
    return _request(
      () => http.get(_uri(path, query), headers: _headers(requiresAuth: requiresAuth)),
      requiresAuth: requiresAuth,
    );
  }

  static Future<dynamic> post(
    String path,
    Map<String, dynamic> body, {
    bool requiresAuth = true,
  }) async {
    return _request(
      () => http.post(
        _uri(path),
        headers: _headers(requiresAuth: requiresAuth),
        body: jsonEncode(body),
      ),
      requiresAuth: requiresAuth,
    );
  }

  static Future<dynamic> _request(
    Future<http.Response> Function() run, {
    required bool requiresAuth,
  }) async {
    var response = await run();
    if (response.statusCode == 401 && requiresAuth) {
      final refreshed = await refreshAuthToken();
      if (refreshed) {
        response = await run();
      }
    }
    return _decode(response);
  }

  static Future<bool> refreshAuthToken() async {
    final refreshToken = AuthStorage.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      await AuthStorage.save(null);
      return false;
    }

    final response = await http.post(
      _uri('/api/auth/refresh'),
      headers: _headers(requiresAuth: false),
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      await AuthStorage.save(null);
      return false;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final sessionMap = json['session'] as Map<String, dynamic>?;
    if (sessionMap == null) {
      await AuthStorage.save(null);
      return false;
    }

    await AuthStorage.save(AuthSession.fromMap(sessionMap));
    return true;
  }

  static dynamic _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(response.body.isNotEmpty
          ? response.body
          : 'Request failed: ${response.statusCode}');
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(response.body);
  }
}
