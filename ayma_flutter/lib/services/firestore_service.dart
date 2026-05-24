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
    final data = doc.data();
    if (data == null) return false;
    // Explicit flag OR has basic profile data (name + gender) = treated as onboarded
    return (data['onboarding_complete'] as bool?) == true ||
        ((data['display_name'] as String?)?.isNotEmpty == true &&
         (data['gender'] as String?) != null);
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

  // ── Questions ─────────────────────────────────────────────────────────────

  static const List<Map<String, dynamic>> _standardQuestions = [
    // Required — must collect early
    {'key': 'name',              'text': "What's their name",                                               'category': 'required',      'order': 1},
    {'key': 'age',               'text': 'How old they are',                                                'category': 'required',      'order': 2},
    {'key': 'gender',            'text': 'Their gender',                                                    'category': 'required',      'order': 3},
    {'key': 'interested_in',     'text': "Who they're interested in (men, women, everyone)",                'category': 'required',      'order': 4},
    {'key': 'location',          'text': "Roughly where they're based",                                     'category': 'required',      'order': 5},
    {'key': 'relationship_goal', 'text': 'What kind of relationship they want (casual, serious, marriage)', 'category': 'required',      'order': 6},
    // Deeper — weave in naturally
    {'key': 'career',            'text': 'What they do for work or study',                                  'category': 'deeper',        'order': 1},
    {'key': 'lifestyle',         'text': 'How they spend their time — social life, hobbies, routines',      'category': 'deeper',        'order': 2},
    {'key': 'values',            'text': 'What matters most to them in life',                               'category': 'deeper',        'order': 3},
    {'key': 'family_views',      'text': 'How they feel about family and kids',                             'category': 'deeper',        'order': 4},
    {'key': 'deal_breakers',     'text': 'What they absolutely cannot compromise on in a partner',          'category': 'deeper',        'order': 5},
    {'key': 'past_relationships','text': 'What their relationship history is like (ask gently)',            'category': 'deeper',        'order': 6},
    {'key': 'love_language',     'text': 'How they show and receive affection',                             'category': 'deeper',        'order': 7},
    {'key': 'fun_quirks',        'text': 'Something surprising or unique about them',                       'category': 'deeper',        'order': 8},
    {'key': 'ideal_date',        'text': 'What their perfect date or evening looks like',                   'category': 'deeper',        'order': 9},
    {'key': 'green_flags',       'text': 'What immediately draws them to someone',                          'category': 'deeper',        'order': 10},
    {'key': 'conflict_style',    'text': 'How they handle disagreements',                                   'category': 'deeper',        'order': 11},
    {'key': 'social_energy',     'text': "Whether they're an introvert, extrovert, or in between",         'category': 'deeper',        'order': 12},
    {'key': 'humor_style',       'text': 'What kind of humor they enjoy',                                   'category': 'deeper',        'order': 13},
    {'key': 'life_ambition',     'text': 'Their big-picture goals for the next few years',                  'category': 'deeper',        'order': 14},
    // Matching prefs
    {'key': 'match_age_range',    'text': 'What age range they are open to',                               'category': 'matching_prefs','order': 1},
    {'key': 'match_location',     'text': 'Whether location matters to them in a match',                   'category': 'matching_prefs','order': 2},
    {'key': 'match_dealbreakers', 'text': "Anything that's a hard no in a potential match",               'category': 'matching_prefs','order': 3},
  ];

  // Call once after onboarding. alreadyAnswered keys are marked answered immediately.
  static Future<void> initializeQuestions({Set<String> alreadyAnswered = const {}}) async {
    final ref = _db.collection('users').doc(_uid).collection('questions');
    final existing = await ref.limit(1).get();
    if (existing.docs.isNotEmpty) return; // already seeded

    final batch = _db.batch();
    for (final q in _standardQuestions) {
      final key = q['key'] as String;
      final answered = alreadyAnswered.contains(key);
      batch.set(ref.doc(), {
        ...q,
        'answered': answered,
        'is_followup': false,
        'created_at': FieldValue.serverTimestamp(),
        if (answered) 'answered_at': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  static Future<void> addFollowupQuestion(String question, {String sessionId = ''}) async {
    await _db.collection('users').doc(_uid).collection('questions').add({
      'key': 'followup_${DateTime.now().millisecondsSinceEpoch}',
      'text': question,
      'category': 'followup',
      'order': 99,
      'answered': false,
      'is_followup': true,
      'session_id': sessionId,
      'created_at': FieldValue.serverTimestamp(),
    });
  }

  static Future<List<Map<String, dynamic>>> getPendingQuestions() async {
    final snap = await _db
        .collection('users')
        .doc(_uid)
        .collection('questions')
        .where('answered', isEqualTo: false)
        .get();
    final docs = snap.docs.map((d) => d.data()..['id'] = d.id).toList();
    // Sort: required first, then deeper, then matching_prefs, then followup
    const order = {'required': 0, 'deeper': 1, 'matching_prefs': 2, 'followup': 3};
    docs.sort((a, b) {
      final catA = order[a['category']] ?? 4;
      final catB = order[b['category']] ?? 4;
      if (catA != catB) return catA.compareTo(catB);
      return ((a['order'] as int?) ?? 0).compareTo((b['order'] as int?) ?? 0);
    });
    return docs;
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
