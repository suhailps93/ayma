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

  static Future<Map<String, dynamic>?> getPublicProfile(String userId) async {
    final userDoc = await _db.collection('users').doc(userId).get();
    if (!userDoc.exists) return null;
    final data = userDoc.data() ?? <String, dynamic>{};
    final mediaSnap = await _db
        .collection('media')
        .where('user_id', isEqualTo: userId)
        .orderBy('created_at', descending: true)
        .limit(24)
        .get();
    final photos = mediaSnap.docs
        .map((d) => (d.data()['photo_url'] as String?) ?? '')
        .where((u) => u.isNotEmpty)
        .toList();
    return {
      ...data,
      'id': userId,
      'photos': photos,
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

  static Stream<List<Map<String, dynamic>>> conversationStream(
      String otherUserId) {
    return _db
        .collection('messages')
        .orderBy('created_at', descending: true)
        .limit(300)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => d.data()..['id'] = d.id)
            .where((m) {
              final from = (m['from_user_id'] as String?) ?? '';
              final to = (m['to_user_id'] as String?) ?? '';
              final betweenMeAndOther =
                  (from == _uid && to == otherUserId) ||
                      (from == otherUserId && to == _uid);
              return betweenMeAndOther;
            })
            .toList()
          ..sort((a, b) {
            final ta = (a['created_at'] as String?) ?? '';
            final tb = (b['created_at'] as String?) ?? '';
            return ta.compareTo(tb);
          }));
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

  static bool inferOnboardingComplete(Map<String, dynamic> data) {
    if ((data['onboarding_complete'] as bool?) == true) return true;

    final displayName = (data['display_name'] as String?)?.trim() ?? '';
    final gender = (data['gender'] as String?)?.trim() ?? '';
    final hasAge = data['age'] is num;
    final locationRegion = (data['location_region'] as String?)?.trim() ?? '';
    final matchingPrefs =
        (data['matching_prefs'] as Map<String, dynamic>?) ?? const {};
    final hasMatchingPrefs = _hasMeaningfulMatchingPrefs(matchingPrefs);
    final hasLegacyProfile =
        _hasMeaningfulText(data['profile_public']) ||
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
    final mediaFuture = _db
        .collection('media')
        .where('user_id', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .limit(20)
        .get();

    final results = await Future.wait([docFuture, mediaFuture]);
    final data =
        (results[0] as DocumentSnapshot).data() as Map<String, dynamic>? ?? {};
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
        date =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
      return '- [$date]($url)\n$caption';
    }).join('\n\n');

    final skills = (data['skills'] as Map<String, dynamic>?) ?? const {};
    final matchingPrefs =
        (data['matching_prefs'] as Map<String, dynamic>?) ?? const {};

    final aboutMe = _firstNonEmpty([
      data['profile_public'],
      data['about_me'],
      skills['about_me'],
      skills['bio'],
    ]) ??
        _composeAboutMeFallback(data);

    final preferences = _firstNonEmpty([
      data['profile_private'],
      data['preferences'],
      skills['preferences'],
      skills['match_preferences'],
    ]) ??
        _composePreferencesFallback(matchingPrefs);

    final context = _firstNonEmpty([
      data['profile_ai_observations'],
      data['context'],
      skills['context'],
      skills['current_chapter'],
    ]) ??
        '';

    return {
      'about_me': aboutMe,
      'preferences': preferences,
      'context': context,
      'media': mediaLines,
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

  static const List<Map<String, dynamic>> _standardQuestions = [
    // Required — must collect early
    {
      'key': 'name',
      'text': "What's their name",
      'category': 'required',
      'order': 1
    },
    {
      'key': 'age',
      'text': 'How old they are',
      'category': 'required',
      'order': 2
    },
    {
      'key': 'gender',
      'text': 'Their gender',
      'category': 'required',
      'order': 3
    },
    {
      'key': 'interested_in',
      'text': "Who they're interested in (men, women, everyone)",
      'category': 'required',
      'order': 4
    },
    {
      'key': 'location',
      'text': "Roughly where they're based",
      'category': 'required',
      'order': 5
    },
    {
      'key': 'relationship_goal',
      'text': 'What kind of relationship they want (casual, serious, marriage)',
      'category': 'required',
      'order': 6
    },
    // Deeper — weave in naturally
    {
      'key': 'career',
      'text': 'What they do for work or study',
      'category': 'deeper',
      'order': 1
    },
    {
      'key': 'lifestyle',
      'text': 'How they spend their time — social life, hobbies, routines',
      'category': 'deeper',
      'order': 2
    },
    {
      'key': 'values',
      'text': 'What matters most to them in life',
      'category': 'deeper',
      'order': 3
    },
    {
      'key': 'family_views',
      'text': 'How they feel about family and kids',
      'category': 'deeper',
      'order': 4
    },
    {
      'key': 'deal_breakers',
      'text': 'What they absolutely cannot compromise on in a partner',
      'category': 'deeper',
      'order': 5
    },
    {
      'key': 'past_relationships',
      'text': 'What their relationship history is like (ask gently)',
      'category': 'deeper',
      'order': 6
    },
    {
      'key': 'love_language',
      'text': 'How they show and receive affection',
      'category': 'deeper',
      'order': 7
    },
    {
      'key': 'fun_quirks',
      'text': 'Something surprising or unique about them',
      'category': 'deeper',
      'order': 8
    },
    {
      'key': 'ideal_date',
      'text': 'What their perfect date or evening looks like',
      'category': 'deeper',
      'order': 9
    },
    {
      'key': 'green_flags',
      'text': 'What immediately draws them to someone',
      'category': 'deeper',
      'order': 10
    },
    {
      'key': 'conflict_style',
      'text': 'How they handle disagreements',
      'category': 'deeper',
      'order': 11
    },
    {
      'key': 'social_energy',
      'text': "Whether they're an introvert, extrovert, or in between",
      'category': 'deeper',
      'order': 12
    },
    {
      'key': 'humor_style',
      'text': 'What kind of humor they enjoy',
      'category': 'deeper',
      'order': 13
    },
    {
      'key': 'life_ambition',
      'text': 'Their big-picture goals for the next few years',
      'category': 'deeper',
      'order': 14
    },
    // Matching prefs
    {
      'key': 'match_age_range',
      'text': 'What age range they are open to',
      'category': 'matching_prefs',
      'order': 1
    },
    {
      'key': 'match_location',
      'text': 'Whether location matters to them in a match',
      'category': 'matching_prefs',
      'order': 2
    },
    {
      'key': 'match_dealbreakers',
      'text': "Anything that's a hard no in a potential match",
      'category': 'matching_prefs',
      'order': 3
    },
  ];

  // Call once after onboarding. alreadyAnswered keys are marked answered immediately.
  static Future<void> initializeQuestions(
      {Set<String> alreadyAnswered = const {}}) async {
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

  static Future<void> addFollowupQuestion(String question,
      {String sessionId = ''}) async {
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
    const order = {
      'required': 0,
      'deeper': 1,
      'matching_prefs': 2,
      'followup': 3
    };
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
    // Keep query shape simple to reduce composite-index requirements.
    final snap = await _db
        .collection('users')
        .where('onboarding_complete', isEqualTo: true)
        .limit(150)
        .get();
    final uid = _uid;
    final lowerQuery = query.toLowerCase();
    final normalizedGenderFilter = _normalizeGender(gender ?? '');
    final genderVariants = _genderVariants(normalizedGenderFilter);
    return snap.docs
        .where((d) => d.id != uid)
        .map((d) => d.data()..['id'] = d.id)
        .where((d) {
      final age = d['age'];
      final ageValue = age is num ? age.toInt() : null;
      if (ageValue == null || ageValue < ageMin || ageValue > ageMax) {
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
