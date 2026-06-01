import 'dart:async';
import 'dart:collection';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/match_model.dart';
import '../models/notification_model.dart';
import '../models/profile.dart';

class FirestoreService {
  FirestoreService._();

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static String get _uid => FirebaseAuth.instance.currentUser!.uid;
  static String uidForClient() => FirebaseAuth.instance.currentUser?.uid ?? '';

  // ── Profile ────────────────────────────────────────────────────────────────

  static Future<UserProfile?> getProfile() async {
    final doc = await _db.collection('users').doc(_uid).get();
    if (!doc.exists) return null;
    final data = doc.data()!..['id'] = _uid;
    return UserProfile.fromMap(data);
  }

  static Stream<UserProfile?> profileStream() =>
      _db.collection('users').doc(_uid).snapshots().map((doc) =>
          doc.exists ? UserProfile.fromMap(doc.data()!..['id'] = _uid) : null);

  static Future<void> updateProfile(Map<String, dynamic> fields) async {
    await _db
        .collection('users')
        .doc(_uid)
        .set(fields, SetOptions(merge: true));
  }

  /// Called when user manually edits their bio — marks it as user-edited.
  static Future<void> saveUserBio(String bio) async {
    await _db.collection('users').doc(_uid).set({
      'profile_public': bio,
      'profile_public_user_edited': true,
    }, SetOptions(merge: true));
  }

  /// Accept Ayma's pending suggestion (optionally edited by user).
  static Future<void> acceptPendingBioSuggestion(String text) async {
    await _db.collection('users').doc(_uid).set({
      'profile_public': text,
      'profile_public_pending': FieldValue.delete(),
    }, SetOptions(merge: true));
  }

  /// Decline Ayma's pending suggestion.
  static Future<void> declinePendingBioSuggestion() async {
    await _db.collection('users').doc(_uid).set({
      'profile_public_pending': FieldValue.delete(),
    }, SetOptions(merge: true));
  }

  static Future<Map<String, dynamic>?> getPublicProfile(String userId) async {
    final userDoc = await _db.collection('users').doc(userId).get();
    if (!userDoc.exists) return null;
    final data = userDoc.data() ?? <String, dynamic>{};
    List<String> photos = const [];
    try {
      final mediaSnap = await _db
          .collection('media')
          .where('user_id', isEqualTo: userId)
          .orderBy('created_at', descending: true)
          .limit(24)
          .get();
      photos = mediaSnap.docs
          .map((d) => (d.data()['photo_url'] as String?) ?? '')
          .where((u) => u.isNotEmpty)
          .toList();
    } catch (_) {
      // Fallback path for environments where orderBy query may be blocked.
      try {
        final mediaSnap = await _db
            .collection('media')
            .where('user_id', isEqualTo: userId)
            .limit(50)
            .get();
        final docs = mediaSnap.docs.toList()
          ..sort((a, b) {
            final ta = a.data()['created_at'];
            final tb = b.data()['created_at'];
            final ma = ta is Timestamp ? ta.millisecondsSinceEpoch : 0;
            final mb = tb is Timestamp ? tb.millisecondsSinceEpoch : 0;
            return mb.compareTo(ma);
          });
        photos = docs
            .map((d) => (d.data()['photo_url'] as String?) ?? '')
            .where((u) => u.isNotEmpty)
            .take(24)
            .toList();
      } catch (_) {
        // Keep profile usable even if media query is denied.
      }
    }
    final dedupedPhotos = LinkedHashSet<String>.from(photos).toList();
    final savedOrder = ((data['photo_order'] as List?) ?? const [])
        .whereType<String>()
        .toList();
    if (savedOrder.isNotEmpty) {
      final rank = <String, int>{
        for (var i = 0; i < savedOrder.length; i++) savedOrder[i]: i,
      };
      dedupedPhotos.sort((a, b) {
        final ra = rank[a] ?? 1 << 20;
        final rb = rank[b] ?? 1 << 20;
        return ra.compareTo(rb);
      });
    }
    return {
      ...data,
      'id': userId,
      'photos': dedupedPhotos,
    };
  }

  static Future<double> generateMatchScore(String otherUserId) async {
    final me = await _db.collection('users').doc(_uid).get();
    final other = await _db.collection('users').doc(otherUserId).get();
    if (!me.exists || !other.exists) return 0.0;
    final a = me.data() ?? <String, dynamic>{};
    final b = other.data() ?? <String, dynamic>{};

    var score = 0.45;
    final aPrefs = (a['matching_prefs'] as Map<String, dynamic>?) ?? const {};
    final bPrefs = (b['matching_prefs'] as Map<String, dynamic>?) ?? const {};
    final aGender = (a['gender'] as String?)?.toLowerCase();
    final bGender = (b['gender'] as String?)?.toLowerCase();
    final aInterested = (aPrefs['interested_in'] as String?)?.toLowerCase();
    final bInterested = (bPrefs['interested_in'] as String?)?.toLowerCase();
    final aAge = a['age'] as int?;
    final bAge = b['age'] as int?;

    bool interested(String? pref, String? targetGender) {
      if (pref == null || pref.isEmpty) return false;
      if (pref == 'everyone') return true;
      if (pref == 'men') return targetGender == 'man' || targetGender == 'male';
      if (pref == 'women') {
        return targetGender == 'woman' || targetGender == 'female';
      }
      return false;
    }

    if (interested(aInterested, bGender)) score += 0.20;
    if (interested(bInterested, aGender)) score += 0.20;

    if (aAge != null && bAge != null) {
      final aMin = aPrefs['age_min'] as int?;
      final aMax = aPrefs['age_max'] as int?;
      final bMin = bPrefs['age_min'] as int?;
      final bMax = bPrefs['age_max'] as int?;
      if (aMin != null && aMax != null && bAge >= aMin && bAge <= aMax) {
        score += 0.08;
      }
      if (bMin != null && bMax != null && aAge >= bMin && aAge <= bMax) {
        score += 0.08;
      }
    }

    return score.clamp(0.0, 0.99);
  }

  static Future<void> sendPoke(String targetUserId) async {
    final me = await _db.collection('users').doc(_uid).get();
    final myName = (me.data()?['display_name'] as String?)?.trim();
    await _db.collection('notifications').add({
      'user_id': targetUserId,
      'type': 'profile_suggestion',
      'title': 'New poke',
      'body': '${myName?.isNotEmpty == true ? myName : 'Someone'} poked you.',
      'read': false,
      'created_at': DateTime.now().toIso8601String(),
      'meta': {'from_user_id': _uid},
    });
  }

  static Future<void> sendDirectMessage({
    required String targetUserId,
    required String text,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await _db.collection('messages').add({
      'from_user_id': _uid,
      'to_user_id': targetUserId,
      'text': clean,
      'created_at': DateTime.now().toIso8601String(),
      'read': false,
    });
    final me = await _db.collection('users').doc(_uid).get();
    final myName = (me.data()?['display_name'] as String?)?.trim();
    await _db.collection('notifications').add({
      'user_id': targetUserId,
      'type': 'agent_update',
      'title': 'New message',
      'body':
          '${myName?.isNotEmpty == true ? myName : 'Someone'} sent you a message.',
      'read': false,
      'created_at': DateTime.now().toIso8601String(),
      'meta': {'from_user_id': _uid},
    });
  }

  static Stream<List<Map<String, dynamic>>> conversationStream(String otherUserId) {
    final uid = _uid;
    final q1 = _db
        .collection('messages')
        .where('from_user_id', isEqualTo: uid)
        .where('to_user_id', isEqualTo: otherUserId)
        .limit(150)
        .snapshots();
    final q2 = _db
        .collection('messages')
        .where('from_user_id', isEqualTo: otherUserId)
        .where('to_user_id', isEqualTo: uid)
        .limit(150)
        .snapshots();

    QuerySnapshot<Map<String, dynamic>>? snap1;
    QuerySnapshot<Map<String, dynamic>>? snap2;
    StreamSubscription? sub1;
    StreamSubscription? sub2;
    late StreamController<List<Map<String, dynamic>>> ctrl;

    void emit() {
      if (snap1 == null || snap2 == null) return;
      final seen = <String>{};
      final combined = <Map<String, dynamic>>[];
      for (final doc in [...snap1!.docs, ...snap2!.docs]) {
        if (seen.add(doc.id)) {
          combined.add(doc.data()..['id'] = doc.id);
        }
      }
      combined.sort((a, b) {
        final ta = (a['created_at'] as String?) ?? '';
        final tb = (b['created_at'] as String?) ?? '';
        return ta.compareTo(tb);
      });
      ctrl.add(combined);
    }

    ctrl = StreamController<List<Map<String, dynamic>>>.broadcast(
      onListen: () {
        sub1 = q1.listen((s) { snap1 = s; emit(); }, onError: ctrl.addError);
        sub2 = q2.listen((s) { snap2 = s; emit(); }, onError: ctrl.addError);
      },
      onCancel: () {
        sub1?.cancel();
        sub2?.cancel();
      },
    );
    return ctrl.stream;
  }

  static Map<String, String> deriveVoiceDefaults({
    String? gender,
    String? locationRegion,
  }) {
    final g = (gender ?? '').toLowerCase().trim();
    final voiceGender = g == 'man' || g == 'male' ? 'female' : 'male';
    final accentLocale = _deriveAccentLocale(locationRegion);
    return {
      'voice_gender': voiceGender,
      'accent_locale': accentLocale,
      'accent_label': accentLocale,
    };
  }

  static String _deriveAccentLocale(String? locationRegion) {
    final loc = (locationRegion ?? '').toLowerCase();
    if (loc.contains('india')) return 'en-IN';
    if (loc.contains('uk') ||
        loc.contains('england') ||
        loc.contains('london') ||
        loc.contains('united kingdom')) {
      return 'en-GB';
    }
    if (loc.contains('australia') || loc.contains('sydney')) return 'en-AU';
    if (loc.contains('canada') || loc.contains('toronto')) return 'en-CA';
    return 'en-US';
  }

  static Future<Map<String, String>> getVoiceSettings() async {
    final doc = await _db.collection('users').doc(_uid).get();
    final data = doc.data() ?? const <String, dynamic>{};
    final saved = (data['voice_settings'] as Map<String, dynamic>?) ?? const {};
    var voiceGender = (saved['voice_gender'] as String?)?.trim();
    var accentLocale = (saved['accent_locale'] as String?)?.trim();
    var accentLabel = (saved['accent_label'] as String?)?.trim();

    if (voiceGender == null ||
        voiceGender.isEmpty ||
        accentLocale == null ||
        accentLocale.isEmpty) {
      final defaults = deriveVoiceDefaults(
        gender: data['gender'] as String?,
        locationRegion: data['location_region'] as String?,
      );
      voiceGender = defaults['voice_gender']!;
      accentLocale = defaults['accent_locale']!;
      accentLabel = defaults['accent_label']!;
      await updateVoiceSettings(
        voiceGender: voiceGender,
        accentLocale: accentLocale,
        accentLabel: accentLabel,
      );
    }
    final resolvedGender = voiceGender;
    final resolvedAccent = accentLocale;
    return {
      'voice_gender': resolvedGender,
      'accent_locale': resolvedAccent,
      'accent_label': (accentLabel == null || accentLabel.isEmpty)
          ? resolvedAccent
          : accentLabel,
    };
  }

  static Future<void> updateVoiceSettings({
    required String voiceGender,
    required String accentLocale,
    String? accentLabel,
  }) async {
    await _db.collection('users').doc(_uid).set({
      'voice_settings': {
        'voice_gender': voiceGender.toLowerCase().trim(),
        'accent_locale': accentLocale.trim(),
        'accent_label': (accentLabel ?? accentLocale).trim(),
      },
      'voice_preference': voiceGender.toLowerCase().trim(),
      'voice_accent': accentLocale.trim(),
      'voice_preferences_updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> clearAymaKnowledge() async {
    final userRef = _db.collection('users').doc(_uid);
    await userRef.set({
      'wiki_about_me': FieldValue.delete(),
      'wiki_about_me_updated_at': FieldValue.delete(),
      'wiki_about_me_session_id': FieldValue.delete(),
      'wiki_preferences': FieldValue.delete(),
      'wiki_preferences_updated_at': FieldValue.delete(),
      'wiki_preferences_session_id': FieldValue.delete(),
      'wiki_context': FieldValue.delete(),
      'wiki_context_updated_at': FieldValue.delete(),
      'wiki_context_session_id': FieldValue.delete(),
      'wiki_matching': FieldValue.delete(),
      'wiki_matching_updated_at': FieldValue.delete(),
      'wiki_matching_session_id': FieldValue.delete(),
    }, SetOptions(merge: true));

    await _deleteSubcollection(
      userRef.collection('memories'),
      orderByField: 'created_at',
    );
    await _deleteSubcollection(
      userRef.collection('questions'),
      orderByField: 'created_at',
    );
    await initializeQuestions();
  }

  static Future<void> _deleteSubcollection(
    Query<Map<String, dynamic>> query, {
    required String orderByField,
  }) async {
    while (true) {
      final snap = await query.orderBy(orderByField).limit(200).get();
      if (snap.docs.isEmpty) return;
      final batch = _db.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      if (snap.docs.length < 200) return;
    }
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
    return docs
        .map((d) => MatchModel.fromMap(d.data()..['id'] = d.id, uid))
        .toList();
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
    final complete = inferOnboardingComplete(data);
    if (complete && (data['onboarding_complete'] as bool?) != true) {
      await _db.collection('users').doc(_uid).set({
        'onboarding_complete': true,
      }, SetOptions(merge: true));
    }
    return complete;
  }

  static Future<void> completeOnboarding() async {
    await _db
        .collection('users')
        .doc(_uid)
        .update({'onboarding_complete': true});
  }

  static Future<void> markPreboardingSeen() async {
    await _db.collection('users').doc(_uid).set({
      'preboarding_seen': true,
    }, SetOptions(merge: true));
  }

  static Future<bool> getPreboardingSeen() async {
    final doc = await _db.collection('users').doc(_uid).get();
    final data = doc.data();
    if (data == null) return false;
    return (data['preboarding_seen'] as bool?) ?? false;
  }

  static bool inferOnboardingComplete(Map<String, dynamic> data) {
    if ((data['onboarding_complete'] as bool?) == true) return true;

    final displayName = (data['display_name'] as String?)?.trim() ?? '';
    final gender = (data['gender'] as String?)?.trim() ?? '';
    final hasAge = data['age'] is num;
    final locationRegion = (data['location_region'] as String?)?.trim() ?? '';
    final matchingPrefs =
        (data['matching_prefs'] as Map<String, dynamic>?) ?? const {};
    final hasMatchingPrefs = _hasMeaningfulMatchingPrefs(matchingPrefs);
    final hasLegacyProfile = _hasMeaningfulText(data['profile_public']) ||
        _hasMeaningfulText(data['profile_private']) ||
        _hasMeaningfulText(data['about_me']) ||
        _hasMeaningfulText(data['preferences']) ||
        _hasMeaningfulText(data['context']) ||
        _hasMeaningfulText(data['profile_ai_observations']);

    final hasCoreOnboardingData =
        displayName.isNotEmpty && gender.isNotEmpty && hasAge;

    return hasCoreOnboardingData &&
        (locationRegion.isNotEmpty || hasMatchingPrefs || hasLegacyProfile);
  }

  static bool _hasMeaningfulText(dynamic value) {
    final text = (value as String?)?.trim() ?? '';
    return text.isNotEmpty;
  }

  static bool _hasMeaningfulMatchingPrefs(Map<String, dynamic> prefs) {
    final interestedIn = (prefs['interested_in'] as String?)?.trim() ?? '';
    final ageMin = prefs['age_min'];
    final ageMax = prefs['age_max'];
    return interestedIn.isNotEmpty || ageMin != null || ageMax != null;
  }

  // ── Insights (memories summary) ────────────────────────────────────────────

  static Future<Map<String, String>> getInsights() async {
    final uid = _uid;
    final docFuture = _db.collection('users').doc(uid).get();
    final mediaFuture = () async {
      try {
        return await _db
            .collection('media')
            .where('user_id', isEqualTo: uid)
            .limit(20)
            .get();
      } catch (_) {
        return null;
      }
    }();

    final results = await Future.wait([docFuture, mediaFuture]);
    final data =
        (results[0] as DocumentSnapshot).data() as Map<String, dynamic>? ?? {};
    final rawMediaDocs =
        (results[1] as QuerySnapshot?)?.docs ?? const <QueryDocumentSnapshot>[];
    final mediaDocs = List<QueryDocumentSnapshot>.from(rawMediaDocs)
      ..sort((a, b) {
        final ta = (a.data() as Map<String, dynamic>)['created_at'];
        final tb = (b.data() as Map<String, dynamic>)['created_at'];
        if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
        return 0;
      });

    // Build media markdown: - [date](url)\ncaption
    final mediaLines = mediaDocs.map((d) {
      final m = d.data() as Map<String, dynamic>;
      final url = (m['photo_url'] as String?) ?? '';
      final caption = (m['caption'] as String?) ?? '';
      final ts = m['created_at'];
      String date = '';
      if (ts is Timestamp) {
        final dt = ts.toDate();
        date =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
      return '- [$date]($url)\n$caption';
    }).join('\n\n');

    final matchingPrefs =
        (data['matching_prefs'] as Map<String, dynamic>?) ?? const {};

    // Wiki fields are AI-maintained by /post-turn — read them directly.
    // profile_public is the separate user-controlled public bio.
    final aboutMe = _firstNonEmpty([
          data['wiki_about_me'],
          data['about_me'],
        ]) ??
        _composeAboutMeFallback(data);

    final preferences = _firstNonEmpty([
          data['wiki_preferences'],
          data['preferences'],
        ]) ??
        _composePreferencesFallback(matchingPrefs);

    final context = _firstNonEmpty([
          data['wiki_context'],
          data['context'],
          data['profile_ai_observations'],
        ]) ??
        '';

    final matching = _firstNonEmpty([data['wiki_matching']]) ?? '';
    final publicProfile = _firstNonEmpty([data['profile_public']]) ?? '';

    // Provenance timestamps — written by /post-turn alongside each wiki update.
    String ts(String key) {
      final v = data[key];
      if (v is Timestamp) {
        final dt = v.toDate().toLocal();
        return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
      return '';
    }

    String sid(String key) => (data[key] as String?) ?? '';

    return {
      'about_me': aboutMe,
      'about_me_updated_at': ts('wiki_about_me_updated_at'),
      'about_me_session_id': sid('wiki_about_me_session_id'),
      'preferences': preferences,
      'preferences_updated_at': ts('wiki_preferences_updated_at'),
      'preferences_session_id': sid('wiki_preferences_session_id'),
      'context': context,
      'context_updated_at': ts('wiki_context_updated_at'),
      'context_session_id': sid('wiki_context_session_id'),
      'matching': matching,
      'matching_updated_at': ts('wiki_matching_updated_at'),
      'matching_session_id': sid('wiki_matching_session_id'),
      'media': mediaLines,
      'public_profile': publicProfile,
    };
  }

  static String? _firstNonEmpty(List<dynamic> values) {
    for (final v in values) {
      final s = (v as String?)?.trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  static String _composeAboutMeFallback(Map<String, dynamic> data) {
    final parts = <String>[];
    final name = (data['display_name'] as String?)?.trim();
    final age = data['age'];
    final gender = (data['gender'] as String?)?.trim();
    final location = (data['location_region'] as String?)?.trim();
    if (name != null && name.isNotEmpty) {
      parts.add(name);
    }
    if (age is int) {
      parts.add('$age');
    }
    if (gender != null && gender.isNotEmpty) {
      parts.add(gender);
    }
    final headline = parts.join(' · ');
    if (headline.isEmpty && (location == null || location.isEmpty)) return '';
    if (location != null && location.isNotEmpty) {
      return headline.isEmpty ? location : '$headline\nBased in $location';
    }
    return headline;
  }

  static String _composePreferencesFallback(Map<String, dynamic> prefs) {
    final interestedIn = (prefs['interested_in'] as String?)?.trim();
    final minAge = prefs['age_min'];
    final maxAge = prefs['age_max'];
    final lines = <String>[];
    if (interestedIn != null && interestedIn.isNotEmpty) {
      lines.add('Interested in: $interestedIn');
    }
    if (minAge is int && maxAge is int) {
      lines.add('Preferred age range: $minAge-$maxAge');
    }
    return lines.join('\n');
  }

  // ── Questions ─────────────────────────────────────────────────────────────

  /// Northstar 45-question profile system.
  static const List<Map<String, dynamic>> _northstarQuestions = [
    // Phase 1 — required core
    {
      'id': 'age',
      'text': 'What is your age?',
      'section': 'basic_identity',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 1,
    },
    {
      'id': 'location_city',
      'text': 'Which city do you currently live in?',
      'section': 'location_mobility',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 3,
    },
    {
      'id': 'max_distance_km',
      'text': 'What is the maximum distance you are comfortable for a match?',
      'section': 'location_mobility',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 4,
    },
    {
      'id': 'willing_to_relocate',
      'text': 'Are you willing to relocate after commitment/marriage?',
      'section': 'location_mobility',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 5,
    },
    {
      'id': 'height_cm',
      'text': 'What is your height (cm)?',
      'section': 'physical_lifestyle',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 6,
    },
    {
      'id': 'education_level',
      'text': 'What is your highest education level?',
      'section': 'education_career',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 7,
    },
    {
      'id': 'occupation',
      'text': 'What is your current occupation?',
      'section': 'education_career',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 8,
    },
    {
      'id': 'relationship_intent',
      'text':
          'Describe your relationship intent in your own words (hookups, casual, long-term, marriage, etc).',
      'section': 'intent_readiness',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 9,
    },
    {
      'id': 'timeline_for_commitment',
      'text': 'When do you want to commit?',
      'section': 'intent_readiness',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 10,
    },
    {
      'id': 'marital_status',
      'text': 'What is your current marital status?',
      'section': 'intent_readiness',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 11,
    },
    {
      'id': 'has_children',
      'text': 'Do you have children?',
      'section': 'children_parenting',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 12,
    },
    {
      'id': 'wants_children',
      'text': 'Do you want children in the future?',
      'section': 'children_parenting',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 13,
    },
    {
      'id': 'smoking_status',
      'text': 'Do you smoke?',
      'section': 'physical_lifestyle',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 14,
    },
    {
      'id': 'alcohol_status',
      'text': 'Do you drink alcohol?',
      'section': 'physical_lifestyle',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 15,
    },
    {
      'id': 'family_type',
      'text': 'What family setup do you prefer after marriage?',
      'section': 'family_background',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'required',
      'order': 16,
    },
    {
      'id': 'partner_non_negotiables',
      'text': 'What are your non-negotiables in a partner?',
      'section': 'partner_preferences',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'matching_prefs',
      'order': 1,
    },
    {
      'id': 'partner_must_haves',
      'text': 'List your top 5 must-haves in a partner.',
      'section': 'partner_preferences',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'matching_prefs',
      'order': 2,
    },
    {
      'id': 'preferred_age_range',
      'text': 'What age range do you prefer in a partner?',
      'section': 'partner_preferences',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 1,
      'category': 'matching_prefs',
      'order': 3,
    },
    // Phase 2 — optional structured
    {
      'id': 'weight_kg',
      'text': 'What is your weight (kg)?',
      'section': 'physical_lifestyle',
      'required': false,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 8,
    },
    {
      'id': 'career_stage',
      'text': 'Which best describes your career stage?',
      'section': 'education_career',
      'required': true,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 1,
    },
    {
      'id': 'diet',
      'text': 'What is your diet preference?',
      'section': 'physical_lifestyle',
      'required': true,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 2,
    },
    {
      'id': 'family_values',
      'text': 'Describe the family values that matter most to you.',
      'section': 'family_background',
      'required': false,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 7,
    },
    {
      'id': 'communication_style',
      'text': 'How do you prefer to communicate in a relationship?',
      'section': 'communication_conflict',
      'required': true,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 3,
    },
    {
      'id': 'conflict_style',
      'text': 'How do you typically handle conflict?',
      'section': 'communication_conflict',
      'required': true,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 4,
    },
    {
      'id': 'preferred_height_range_cm',
      'text': 'What height range do you prefer in a partner (cm)?',
      'section': 'partner_preferences',
      'required': false,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'matching_prefs',
      'order': 4,
    },
    {
      'id': 'bio_relationship_offer',
      'text': 'What do you offer in a relationship?',
      'section': 'depth_authenticity',
      'required': true,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 5,
    },
    {
      'id': 'bio_relationship_need',
      'text': 'What do you need most from a partner?',
      'section': 'depth_authenticity',
      'required': true,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 6,
    },
    {
      'id': 'ai_profile_summary',
      'text': 'AI-generated profile summary from answered fields.',
      'section': 'ai_profile_summary',
      'required': true,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 21,
    },
    {
      'id': 'past_relationship_learnings',
      'text': 'What did you learn from past relationships?',
      'section': 'relationship_history',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 13,
    },
    {
      'id': 'friends_social_style',
      'text': 'How active is your social/friends life?',
      'section': 'social_life',
      'required': false,
      'sensitive_flag': false,
      'priority': 'low',
      'phase': 2,
      'category': 'deeper',
      'order': 14,
    },
    {
      'id': 'has_pets',
      'text': 'Do you have pets?',
      'section': 'social_life',
      'required': false,
      'sensitive_flag': false,
      'priority': 'low',
      'phase': 2,
      'category': 'deeper',
      'order': 15,
    },
    {
      'id': 'pet_details',
      'text': 'What pets do you have?',
      'section': 'social_life',
      'required': false,
      'sensitive_flag': false,
      'priority': 'low',
      'phase': 2,
      'category': 'deeper',
      'order': 16,
    },
    // Phase 3 — sensitive opt-in
    {
      'id': 'gender_identity',
      'text': 'What is your gender identity?',
      'section': 'basic_identity',
      'required': true,
      'sensitive_flag': true,
      'priority': 'high',
      'phase': 3,
      'category': 'required',
      'order': 2,
    },
    {
      'id': 'religion',
      'text': 'What is your religion?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': true,
      'priority': 'high',
      'phase': 3,
      'category': 'deeper',
      'order': 9,
    },
    {
      'id': 'religious_practice_level',
      'text': 'How actively do you practice your religion?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 10,
    },
    {
      'id': 'income_band',
      'text': 'What is your approximate income band?',
      'section': 'financial_compatibility',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 11,
    },
    {
      'id': 'race',
      'text': 'What is your race/ethnicity?',
      'section': 'sensitive_attributes',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 12,
    },
    {
      'id': 'caste',
      'text': 'Do you want to share your caste?',
      'section': 'sensitive_attributes',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'deeper',
      'order': 17,
    },
    {
      'id': 'sub_caste',
      'text': 'Do you want to share your sub-caste/community details?',
      'section': 'sensitive_attributes',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'deeper',
      'order': 18,
    },
    {
      'id': 'skin_tone',
      'text': 'Do you want to share your skin tone?',
      'section': 'sensitive_attributes',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'deeper',
      'order': 19,
    },
    {
      'id': 'past_relationship_count',
      'text': 'How many serious past relationships have you had?',
      'section': 'relationship_history',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'deeper',
      'order': 20,
    },
    {
      'id': 'preferred_religion',
      'text': 'Do you have a religion preference for your partner?',
      'section': 'partner_preferences_sensitive',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'matching_prefs',
      'order': 5,
    },
    {
      'id': 'preferred_caste',
      'text': 'Do you have a caste preference for your partner?',
      'section': 'partner_preferences_sensitive',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'matching_prefs',
      'order': 6,
    },
    {
      'id': 'preferred_sub_caste',
      'text': 'Do you have a sub-caste/community preference for your partner?',
      'section': 'partner_preferences_sensitive',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'matching_prefs',
      'order': 7,
    },
    {
      'id': 'preferred_race_ethnicity',
      'text': 'Do you have a race/ethnicity preference for your partner?',
      'section': 'partner_preferences_sensitive',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'matching_prefs',
      'order': 8,
    },
  ];

  /// Backward-compat alias.
  // ignore: unused_field
  static const List<Map<String, dynamic>> _standardQuestions =
      _northstarQuestions;

  /// Maps each question id to its scoring bucket.
  static const Map<String, String> _questionScoringBucket = {
    // core_matchability
    'age': 'core_matchability',
    'gender_identity': 'core_matchability',
    'location_city': 'core_matchability',
    'max_distance_km': 'core_matchability',
    'willing_to_relocate': 'core_matchability',
    'height_cm': 'core_matchability',
    'education_level': 'core_matchability',
    'occupation': 'core_matchability',
    'career_stage': 'core_matchability',
    'income_band': 'core_matchability',
    'has_children': 'core_matchability',
    'wants_children': 'core_matchability',
    // intent_and_readiness
    'relationship_intent': 'intent_and_readiness',
    'timeline_for_commitment': 'intent_and_readiness',
    'marital_status': 'intent_and_readiness',
    // lifestyle_compatibility
    'weight_kg': 'lifestyle_compatibility',
    'diet': 'lifestyle_compatibility',
    'smoking_status': 'lifestyle_compatibility',
    'alcohol_status': 'lifestyle_compatibility',
    'communication_style': 'lifestyle_compatibility',
    'conflict_style': 'lifestyle_compatibility',
    'friends_social_style': 'lifestyle_compatibility',
    'has_pets': 'lifestyle_compatibility',
    'pet_details': 'lifestyle_compatibility',
    // values_and_family_alignment
    'religion': 'values_and_family_alignment',
    'religious_practice_level': 'values_and_family_alignment',
    'skin_tone': 'values_and_family_alignment',
    'race': 'values_and_family_alignment',
    'caste': 'values_and_family_alignment',
    'sub_caste': 'values_and_family_alignment',
    'family_type': 'values_and_family_alignment',
    'family_values': 'values_and_family_alignment',
    'past_relationship_count': 'values_and_family_alignment',
    'past_relationship_learnings': 'values_and_family_alignment',
    // depth_and_authenticity
    'partner_non_negotiables': 'depth_and_authenticity',
    'partner_must_haves': 'depth_and_authenticity',
    'preferred_age_range': 'depth_and_authenticity',
    'preferred_height_range_cm': 'depth_and_authenticity',
    'preferred_religion': 'depth_and_authenticity',
    'preferred_caste': 'depth_and_authenticity',
    'preferred_sub_caste': 'depth_and_authenticity',
    'preferred_race_ethnicity': 'depth_and_authenticity',
    'bio_relationship_offer': 'depth_and_authenticity',
    'bio_relationship_need': 'depth_and_authenticity',
    'ai_profile_summary': 'depth_and_authenticity',
  };

  // ── Profile Answers ────────────────────────────────────────────────────────

  /// Reads the user's profile_answers map from their user doc.
  static Future<Map<String, dynamic>> getProfileAnswers() async {
    try {
      final doc = await _db.collection('users').doc(_uid).get();
      if (!doc.exists) return {};
      final data = doc.data() ?? {};
      final answers = data['profile_answers'];
      if (answers is Map<String, dynamic>) return answers;
      return {};
    } catch (_) {
      return {};
    }
  }

  /// Merges a single answer into users/{uid}.profile_answers.{questionId}.
  static Future<void> saveProfileAnswer(
      String questionId, dynamic value) async {
    await _db.collection('users').doc(_uid).set({
      'profile_answers': {questionId: value},
    }, SetOptions(merge: true));
  }

  /// Weighted completeness score 0–100.
  /// Checks both profile_answers and legacy profileData fields.
  static double computeProfileCompleteness(
    Map<String, dynamic> answers,
    Map<String, dynamic> profileData,
  ) {
    const bucketWeights = <String, double>{
      'core_matchability': 40.0,
      'intent_and_readiness': 20.0,
      'lifestyle_compatibility': 15.0,
      'values_and_family_alignment': 15.0,
      'depth_and_authenticity': 10.0,
    };

    // Legacy field mappings: questionId → profileData key
    const legacyMap = <String, String>{
      'age': 'age',
      'gender_identity': 'gender',
      'location_city': 'location_region',
      'occupation': 'occupation',
      'height_cm': 'height_cm',
    };

    // Group questions by bucket
    final bucketQuestions = <String, List<Map<String, dynamic>>>{};
    for (final q in _northstarQuestions) {
      final bucket =
          _questionScoringBucket[q['id'] as String] ?? 'depth_and_authenticity';
      bucketQuestions.putIfAbsent(bucket, () => []).add(q);
    }

    double total = 0.0;

    for (final entry in bucketWeights.entries) {
      final bucketName = entry.key;
      final weight = entry.value;
      final questions = bucketQuestions[bucketName] ?? [];
      if (questions.isEmpty) continue;

      double achieved = 0.0;
      double maxPossible = 0.0;

      for (final q in questions) {
        final id = q['id'] as String;
        final isRequired = (q['required'] as bool?) ?? false;
        final questionMax = isRequired ? 1.0 : 0.6;
        maxPossible += questionMax;

        // Check answers map first, then legacy profileData
        dynamic val = answers[id];
        if (_isEmptyValue(val)) {
          final legacyKey = legacyMap[id];
          if (legacyKey != null) {
            val = profileData[legacyKey];
          }
        }

        if (_isEmptyValue(val)) {
          // unanswered — 0 contribution
        } else if (val == 'prefer_not_to_say') {
          achieved += 0.2;
        } else {
          achieved += questionMax;
        }
      }

      if (maxPossible > 0) {
        total += (achieved / maxPossible) * weight;
      }
    }

    return total.clamp(0.0, 100.0);
  }

  static bool _isEmptyValue(dynamic val) {
    if (val == null) return true;
    if (val is String && val.trim().isEmpty) return true;
    return false;
  }

  /// Reads answers and user doc, returns completeness score 0–100.
  static Future<double> getProfileCompleteness() async {
    final doc = await _db.collection('users').doc(_uid).get();
    final profileData = doc.exists ? (doc.data() ?? {}) : <String, dynamic>{};
    final answers = profileData['profile_answers'];
    final answersMap =
        (answers is Map<String, dynamic>) ? answers : <String, dynamic>{};
    return computeProfileCompleteness(answersMap, profileData);
  }

  // ── Questions ─────────────────────────────────────────────────────────────

  // Call once after onboarding. alreadyAnswered keys are marked answered immediately.
  static Future<void> initializeQuestions(
      {Set<String> alreadyAnswered = const {}}) async {
    final ref = _db.collection('users').doc(_uid).collection('questions');
    final existing = await ref.get();

    bool needsReseed = existing.docs.isEmpty;
    if (!needsReseed && existing.docs.length < 20) {
      needsReseed = true;
    }
    if (!needsReseed) {
      // Check whether any existing doc has a key matching a northstar id
      final northstarIds =
          _northstarQuestions.map((q) => q['id'] as String).toSet();
      final hasNorthstar = existing.docs.any((d) {
        final id = d.data()['id'] as String?;
        return id != null && northstarIds.contains(id);
      });
      if (!hasNorthstar) needsReseed = true;
    }
    if (!needsReseed) {
      // Check whether existing docs are missing category/order fields
      final missingFields = existing.docs.any((d) {
        final data = d.data();
        return data['category'] == null || data['order'] == null;
      });
      if (missingFields) needsReseed = true;
    }

    if (!needsReseed) return;

    // Delete all existing questions
    final deleteBatch = _db.batch();
    for (final doc in existing.docs) {
      deleteBatch.delete(doc.reference);
    }
    if (existing.docs.isNotEmpty) await deleteBatch.commit();

    // Seed northstar questions
    final batch = _db.batch();
    for (final q in _northstarQuestions) {
      final id = q['id'] as String;
      final answered = alreadyAnswered.contains(id);
      batch.set(ref.doc(), {
        'id': id,
        'key': id,
        'text': q['text'],
        'section': q['section'],
        'required': q['required'],
        'sensitive_flag': q['sensitive_flag'],
        'priority': q['priority'],
        'phase': q['phase'],
        'category': q['category'],
        'order': q['order'],
        'answered': answered,
        'answered_value': null,
        'is_followup': false,
        'created_at': FieldValue.serverTimestamp(),
        if (answered) 'answered_at': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  static Future<void> addFollowupQuestion(String question,
      {String sessionId = ''}) async {
    await _db.collection('users').doc(_uid).collection('questions').add({
      'key': 'followup_${DateTime.now().millisecondsSinceEpoch}',
      'id': 'followup_${DateTime.now().millisecondsSinceEpoch}',
      'text': question,
      'section': 'followup',
      'phase': 99,
      'priority': 'low',
      'required': false,
      'sensitive_flag': false,
      'answered': false,
      'answered_value': null,
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

    const priorityOrder = {'high': 0, 'medium': 1, 'low': 2};

    docs.sort((a, b) {
      // Phase first (1 before 2 before 3)
      final phaseA = (a['phase'] as int?) ?? 99;
      final phaseB = (b['phase'] as int?) ?? 99;
      if (phaseA != phaseB) return phaseA.compareTo(phaseB);

      // Then priority
      final prioA = priorityOrder[(a['priority'] as String?) ?? 'low'] ?? 3;
      final prioB = priorityOrder[(b['priority'] as String?) ?? 'low'] ?? 3;
      if (prioA != prioB) return prioA.compareTo(prioB);

      // Then order (legacy field, fallback 0)
      return ((a['order'] as int?) ?? 0).compareTo((b['order'] as int?) ?? 0);
    });
    return docs;
  }

  /// Marks a question answered in the questions sub-collection and saves
  /// the value to profile_answers.
  static Future<void> markQuestionAnswered(
      String questionId, dynamic value) async {
    final ref = _db.collection('users').doc(_uid).collection('questions');
    final snap =
        await ref.where('id', isEqualTo: questionId).limit(1).get();
    if (snap.docs.isNotEmpty) {
      await snap.docs.first.reference.update({
        'answered': true,
        'answered_value': value,
        'answered_at': FieldValue.serverTimestamp(),
      });
    }
    await saveProfileAnswer(questionId, value);
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

  static Future<void> deleteMediaByUrl(String photoUrl) async {
    final snap = await _db
        .collection('media')
        .where('user_id', isEqualTo: _uid)
        .where('photo_url', isEqualTo: photoUrl)
        .get();
    if (snap.docs.isEmpty) return;
    final batch = _db.batch();
    for (final d in snap.docs) {
      batch.delete(d.reference);
    }
    batch.set(
        _db.collection('users').doc(_uid),
        {
          'photo_order': FieldValue.arrayRemove([photoUrl]),
        },
        SetOptions(merge: true));
    await batch.commit();
  }

  static Future<void> updatePhotoOrder(List<String> orderedUrls) async {
    await _db.collection('users').doc(_uid).set({
      'photo_order': orderedUrls,
    }, SetOptions(merge: true));
  }

  // ── Explore ────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> explore({
    String? gender,
    int ageMin = 0,
    int ageMax = 120,
    String query = '',
  }) async {
    // Keep query shape simple to reduce composite-index requirements.
    final snap = await _db
        .collection('users')
        .where('onboarding_complete', isEqualTo: true)
        .limit(150)
        .get();
    final lowerQuery = query.toLowerCase();
    final normalizedGenderFilter = _normalizeGender(gender ?? '');
    final genderVariants = _genderVariants(normalizedGenderFilter);
    final people = snap.docs.map((d) => d.data()..['id'] = d.id).where((d) {
      final age = d['age'];
      final ageValue = age is num ? age.toInt() : null;
      if (ageValue != null && (ageValue < ageMin || ageValue > ageMax)) {
        return false;
      }

      if (genderVariants.isNotEmpty) {
        final normalizedDocGender =
            _normalizeGender((d['gender'] as String?) ?? '');
        if (!genderVariants.contains(normalizedDocGender)) {
          return false;
        }
      }

      if (lowerQuery.isEmpty) return true;
      final name = ((d['display_name'] as String?) ?? '').toLowerCase();
      final bio = ((d['profile_public'] as String?) ?? '').toLowerCase();
      return name.contains(lowerQuery) || bio.contains(lowerQuery);
    }).toList();

    // Ensure the current user's own profile is visible in Explore too.
    final myDoc = await _db.collection('users').doc(_uid).get();
    final myData = myDoc.data();
    if (myData != null) {
      final mine = <String, dynamic>{...myData, 'id': _uid};
      final alreadyIncluded = people.any((p) => (p['id'] as String?) == _uid);
      if (!alreadyIncluded) {
        people.add(mine);
      }
    }

    // Stable, neutral ordering (not pinned to top).
    people.sort((a, b) {
      final an = ((a['display_name'] as String?) ?? '').toLowerCase();
      final bn = ((b['display_name'] as String?) ?? '').toLowerCase();
      return an.compareTo(bn);
    });
    return people;
  }

  static String _normalizeGender(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'woman' || v == 'women' || v == 'female' || v == 'f') {
      return 'woman';
    }
    if (v == 'man' || v == 'men' || v == 'male' || v == 'm') {
      return 'man';
    }
    return v;
  }

  static Set<String> _genderVariants(String normalized) {
    if (normalized.isEmpty) return const {};
    if (normalized == 'woman') {
      return const {'woman', 'women'};
    }
    if (normalized == 'man') {
      return const {'man', 'men'};
    }
    return {normalized};
  }
}
