// Thin client for the Cloud Run bootstrap function.
// All data (profiles, matches, notifications) goes via Firestore directly.
// Only bootstrap and post-turn memory extraction go through here.

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
    if (token == null) throw Exception('Not authenticated');

    final response = await http
        .post(
          Uri.parse('${Env.bootstrapUrl}/post-turn'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'session_id': sessionId, 'messages': messages}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('post-turn failed: ${response.statusCode} ${response.body}');
    }
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
        .timeout(const Duration(seconds: 90));

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
          body: jsonEncode({'match_id': int.tryParse(matchId) ?? 0}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Vibe check failed: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<String> uploadMedia(Uint8List bytes, String filename) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception('Not authenticated');

    final safeName = filename.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final ref = FirebaseStorage.instance
        .ref()
        .child('media/$uid/${DateTime.now().millisecondsSinceEpoch}_$safeName');

    final task = await ref.putData(
      bytes,
      SettableMetadata(contentType: _mimeType(filename)),
    );
    return await task.ref.getDownloadURL();
  }

  static Future<void> saveDeviceToken(String token) async {
    final idToken = await _idToken();
    if (idToken == null) return;
    await http.post(
      Uri.parse('${Env.bootstrapUrl}/device-token'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $idToken'},
      body: jsonEncode({'token': token}),
    );
  }

  // Uses putFile() on native to avoid loading large video files into memory.
  // Falls back to putData() on web (where dart:io File is unavailable).
  static Future<String> uploadMediaPath(String filePath, String filename) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception('Not authenticated');

    final safeName = filename.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final ref = FirebaseStorage.instance
        .ref()
        .child('media/$uid/${DateTime.now().millisecondsSinceEpoch}_$safeName');

    final meta = SettableMetadata(contentType: _mimeType(filename));
    final TaskSnapshot task;
    if (kIsWeb) {
      final bytes = await io.File(filePath).readAsBytes();
      task = await ref.putData(bytes, meta);
    } else {
      task = await ref.putFile(io.File(filePath), meta);
    }
    return await task.ref.getDownloadURL();
  }

  static String _mimeType(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      _ => 'image/jpeg', // image_picker on Android often returns files without extension
    };
  }
}
