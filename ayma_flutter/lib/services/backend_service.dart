// Thin client for the Cloud Run bootstrap function.
// All data (profiles, matches, notifications) goes via Firestore directly.
// Only bootstrap and post-turn memory extraction go through here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:http/http.dart' as http;

import '../env.dart';

class BackendService {
  BackendService._();

  static Future<String?> _idToken() async =>
      FirebaseAuth.instance.currentUser?.getIdToken();

  static Future<Map<String, dynamic>> bootstrap() async {
    final token = await _idToken();
    if (token == null) throw Exception('Not authenticated');

    final response = await http.post(
      Uri.parse('${Env.bootstrapUrl}/bootstrap'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Bootstrap failed: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> postTurn({
    required String sessionId,
    required List<Map<String, String>> messages,
  }) async {
    final token = await _idToken();
    if (token == null) return;

    await http
        .post(
          Uri.parse('${Env.bootstrapUrl}/post-turn'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'session_id': sessionId, 'messages': messages}),
        )
        .timeout(const Duration(seconds: 15));
  }

  static Future<Map<String, dynamic>> runMatching() async {
    final token = await _idToken();
    if (token == null) throw Exception('Not authenticated');

    final response = await http
        .post(
          Uri.parse('${Env.bootstrapUrl}/run-matching'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode != 200) {
      throw Exception('Matching failed: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> vibeCheck(String matchId) async {
    final token = await _idToken();
    if (token == null) throw Exception('Not authenticated');

    final response = await http
        .post(
          Uri.parse('${Env.bootstrapUrl}/vibe-check'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'match_id': matchId}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('vibe-check failed: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<String> uploadMedia(Uint8List bytes, String filename) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception('Not authenticated');

    final ref = FirebaseStorage.instance
        .ref()
        .child('media/$uid/${DateTime.now().millisecondsSinceEpoch}_$filename');

    final task = await ref.putData(
      bytes,
      SettableMetadata(contentType: _mimeType(filename)),
    );
    return await task.ref.getDownloadURL();
  }

  static String _mimeType(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      _ => 'application/octet-stream',
    };
  }
}
