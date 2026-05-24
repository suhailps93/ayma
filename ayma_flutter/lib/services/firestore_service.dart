import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/match_model.dart';
import '../models/notification_model.dart';
import '../models/profile.dart';

class FirestoreService {
  FirestoreService._();

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static String get _uid => FirebaseAuth.instance.currentUser!.uid;

  // ── Profile ────────────────────────────────────────────────────────────────

  static Future<UserProfile?> getProfile() async {
    final doc = await _db.collection('users').doc(_uid).get();
    if (!doc.exists) return null;
    final data = doc.data()!..['id'] = _uid;
    return UserProfile.fromMap(data);
  }

  static Stream<UserProfile?> profileStream() => _db
      .collection('users')
      .doc(_uid)
      .snapshots()
      .map((doc) => doc.exists ? UserProfile.fromMap(doc.data()!..['id'] = _uid) : null);

  static Future<void> updateProfile(Map<String, dynamic> fields) async {
    await _db.collection('users').doc(_uid).set(fields, SetOptions(merge: true));
  }

  // ── Matches ────────────────────────────────────────────────────────────────

  static Future<List<MatchModel>> getMatches() async {
    final uid = _uid;
    final queryA = await _db
        .collection('matches')
        .where('user_a', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .get();
    final queryB = await _db
        .collection('matches')
        .where('user_b', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .get();
    final docs = {...queryA.docs, ...queryB.docs};
    return docs.map((d) => MatchModel.fromMap(d.data()..['id'] = d.id, uid)).toList();
  }

  static Future<void> updateMatchStatus(String matchId, String status) async {
    await _db.collection('matches').doc(matchId).update({'status': status});
  }

  // ── Notifications ──────────────────────────────────────────────────────────

  static Future<List<NotificationModel>> getNotifications() async {
    final snap = await _db
        .collection('notifications')
        .where('user_id', isEqualTo: _uid)
        .orderBy('created_at', descending: true)
        .limit(50)
        .get();
    return snap.docs
        .map((d) => NotificationModel.fromMap(d.data()..['id'] = d.id))
        .toList();
  }

  static Stream<List<NotificationModel>> notificationsStream() => _db
      .collection('notifications')
      .where('user_id', isEqualTo: _uid)
      .orderBy('created_at', descending: true)
      .limit(50)
      .snapshots()
      .map((s) => s.docs
          .map((d) => NotificationModel.fromMap(d.data()..['id'] = d.id))
          .toList());

  static Future<void> markNotificationRead(String id) async {
    await _db.collection('notifications').doc(id).update({'read': true});
  }

  static Future<void> markAllNotificationsRead() async {
    final uid = _uid;
    final snap = await _db
        .collection('notifications')
        .where('user_id', isEqualTo: uid)
        .where('read', isEqualTo: false)
        .get();
    final batch = _db.batch();
    for (final doc in snap.docs) {
      batch.update(doc.reference, {'read': true});
    }
    await batch.commit();
  }

  // ── Onboarding ─────────────────────────────────────────────────────────────

  static Future<bool> getOnboardingStatus() async {
    final doc = await _db.collection('users').doc(_uid).get();
    return (doc.data()?['onboarding_complete'] as bool?) ?? false;
  }

  static Future<void> completeOnboarding() async {
    await _db.collection('users').doc(_uid).update({'onboarding_complete': true});
  }

  // ── Insights (memories summary) ────────────────────────────────────────────

  static Future<Map<String, String>> getInsights() async {
    final uid = _uid;
    final docFuture = _db.collection('users').doc(uid).get();
    final mediaFuture = _db
        .collection('media')
        .where('user_id', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .limit(20)
        .get();

    final results = await Future.wait([docFuture, mediaFuture]);
    final data = (results[0] as DocumentSnapshot).data() as Map<String, dynamic>? ?? {};
    final mediaDocs = (results[1] as QuerySnapshot).docs;

    // Build media markdown: - [date](url)\ncaption
    final mediaLines = mediaDocs.map((d) {
      final m = d.data() as Map<String, dynamic>;
      final url = (m['photo_url'] as String?) ?? '';
      final caption = (m['caption'] as String?) ?? '';
      final ts = m['created_at'];
      String date = '';
      if (ts is Timestamp) {
        final dt = ts.toDate();
        date = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
      return '- [$date]($url)\n$caption';
    }).join('\n\n');

    return {
      'about_me': (data['profile_public'] as String?) ?? '',
      'preferences': (data['profile_private'] as String?) ?? '',
      'context': (data['profile_ai_observations'] as String?) ?? '',
      'media': mediaLines,
    };
  }

  // ── Media ──────────────────────────────────────────────────────────────────

  static Future<void> saveMediaRecord({
    required String photoUrl,
    String caption = '',
  }) async {
    await _db.collection('media').add({
      'user_id': _uid,
      'photo_url': photoUrl,
      'caption': caption,
      'created_at': FieldValue.serverTimestamp(),
    });
  }

  // ── Explore ────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> explore({
    String? gender,
    int ageMin = 18,
    int ageMax = 60,
    String query = '',
  }) async {
    var q = _db.collection('users').where('onboarding_complete', isEqualTo: true);
    if (gender != null && gender.isNotEmpty) {
      q = q.where('gender', isEqualTo: gender);
    }
    q = q.where('age', isGreaterThanOrEqualTo: ageMin)
         .where('age', isLessThanOrEqualTo: ageMax);
    final snap = await q.limit(50).get();
    final uid = _uid;
    final lowerQuery = query.toLowerCase();
    return snap.docs
        .where((d) => d.id != uid)
        .map((d) => d.data()..['id'] = d.id)
        .where((d) {
          if (lowerQuery.isEmpty) return true;
          final name = ((d['display_name'] as String?) ?? '').toLowerCase();
          final bio = ((d['profile_public'] as String?) ?? '').toLowerCase();
          return name.contains(lowerQuery) || bio.contains(lowerQuery);
        })
        .toList();
  }
}
