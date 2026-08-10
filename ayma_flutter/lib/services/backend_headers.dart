import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';

class BackendHeaders {
  BackendHeaders._();

  static Future<Map<String, String>> jsonAuth({
    Map<String, String>? extra,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (idToken != null) {
      headers['Authorization'] = 'Bearer $idToken';
    }

    try {
      final appCheckToken = await FirebaseAppCheck.instance.getToken();
      if (appCheckToken != null && appCheckToken.isNotEmpty) {
        headers['X-Firebase-AppCheck'] = appCheckToken;
      }
    } catch (_) {}

    if (extra != null) {
      headers.addAll(extra);
    }
    return headers;
  }
}
