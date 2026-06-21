// Authenticated HTTP client for all backend data: profile, matches, explore, messages, questions.
import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../env.dart';
import '../models/community_profile.dart';
import '../models/match_model.dart';
import '../models/notification_model.dart';
import '../models/profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  ApiService._();

  static String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  static String _onboardingKey() => 'ayma.onboarding_complete.$_uid';
  static String _preboardingKey() => 'ayma.preboarding_seen.$_uid';
  static String uidForClient() => FirebaseAuth.instance.currentUser?.uid ?? '';

  static Future<String?> _idToken() async =>
      FirebaseAuth.instance.currentUser?.getIdToken();

  static Future<http.Response> _get(
    String path, {
    Map<String, String>? extraHeaders,
  }) async {
    final token = await _idToken();
    return http.get(
      Uri.parse('${Env.bootstrapUrl}$path'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
        ...?extraHeaders,
      },
    );
  }

  static Future<http.Response> _post(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? extraHeaders,
  }) async {
    final token = await _idToken();
    return http.post(
      Uri.parse('${Env.bootstrapUrl}$path'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
        ...?extraHeaders,
      },
      body: jsonEncode(body),
    );
  }

  static Future<http.Response> _delete(String path, Map<String, dynamic> body) async {
    final token = await _idToken();
    final request = http.Request('DELETE', Uri.parse('${Env.bootstrapUrl}$path'));
    request.headers.addAll({
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    });
    request.body = jsonEncode(body);
    final streamedResponse = await request.send();
    return http.Response.fromStream(streamedResponse);
  }

  // ── Profile ────────────────────────────────────────────────────────────────

  static Future<UserProfile?> getProfile() async {
    final response = await _get('/profile');
    if (response.statusCode != 200) {
      throw Exception('Failed to load profile: ${response.statusCode}');
    }
    final Map<String, dynamic> data = jsonDecode(response.body);
    return UserProfile.fromMap(data);
  }

  static Stream<UserProfile?> profileStream() async* {
    while (true) {
      await Future.delayed(const Duration(seconds: 10));
      yield await getProfile();
    }
  }

  static Future<void> updateProfile(Map<String, dynamic> fields) async {
    await _post('/profile', fields);
  }

  /// Called when user manually edits their bio — marks it as user-edited.
  static Future<void> saveUserBio(String bio) async {
    await updateProfile({
      'profile_public': bio,
      'profile_public_user_edited': true,
    });
  }

  /// Accept Ayma's pending suggestion (optionally edited by user).
  static Future<void> acceptPendingBioSuggestion(String text) async {
    await updateProfile({
      'profile_public': text,
      'profile_public_pending': '',
    });
  }

  /// Decline Ayma's pending suggestion.
  static Future<void> declinePendingBioSuggestion() async {
    await updateProfile({
      'profile_public_pending': '',
    });
  }

  static Future<Map<String, dynamic>?> getPublicProfile(String userId) async {
    final response = await _get('/profile/$userId/public');
    if (response.statusCode != 200) return null;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<double> generateMatchScore(String otherUserId) async {
    return 0.5; // Calculated backend-side in production
  }

  static Future<void> sendPoke(String targetUserId) async {
    await sendDirectMessage(targetUserId: targetUserId, text: "*Poked you*");
  }

  static Future<void> sendDirectMessage({
    required String targetUserId,
    required String text,
  }) async {
    await _post('/messages', {'target_user_id': targetUserId, 'text': text});
  }

  static Stream<List<Map<String, dynamic>>> conversationStream(String otherUserId) async* {
    while (true) {
      try {
        final response = await _get('/messages/$otherUserId');
        if (response.statusCode == 200) {
          final List<dynamic> list = jsonDecode(response.body);
          yield list.cast<Map<String, dynamic>>();
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  // ── Admin ──────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getAdminUsers({
    required String adminPassword,
    String query = '',
    String? gender,
    String? communityProfile,
    String? intentType,
    bool? onboardingComplete,
    bool? matchingPaused,
    bool? hasPhotos,
    bool? hasMatches,
    bool? hasMessages,
    int? minAge,
    int? maxAge,
    int limit = 100,
  }) async {
    final qp = <String, String>{
      if (query.trim().isNotEmpty) 'query': query.trim(),
      if ((gender ?? '').trim().isNotEmpty) 'gender': gender!.trim(),
      if ((communityProfile ?? '').trim().isNotEmpty)
        'community_profile': communityProfile!.trim(),
      if ((intentType ?? '').trim().isNotEmpty) 'intent_type': intentType!.trim(),
      if (onboardingComplete != null) 'onboarding_complete': '$onboardingComplete',
      if (matchingPaused != null) 'matching_paused': '$matchingPaused',
      if (hasPhotos != null) 'has_photos': '$hasPhotos',
      if (hasMatches != null) 'has_matches': '$hasMatches',
      if (hasMessages != null) 'has_messages': '$hasMessages',
      if (minAge != null) 'min_age': '$minAge',
      if (maxAge != null) 'max_age': '$maxAge',
      'limit': '$limit',
    };
    final uri = Uri.parse('${Env.bootstrapUrl}/admin/users')
        .replace(queryParameters: qp);
    final token = await _idToken();
    final response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
        'X-Admin-Password': adminPassword,
      },
    );
    if (response.statusCode != 200) {
      throw Exception('Admin users failed: ${response.statusCode} ${response.body}');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>> getAdminUserDetail({
    required String userId,
    required String adminPassword,
  }) async {
    final response = await _get(
      '/admin/users/$userId',
      extraHeaders: {'X-Admin-Password': adminPassword},
    );
    if (response.statusCode != 200) {
      throw Exception('Admin user detail failed: ${response.statusCode} ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
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
    final response = await _get('/profile');
    if (response.statusCode != 200) return const {};
    final data = jsonDecode(response.body) as Map<String, dynamic>;
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
    await updateProfile({
      'voice_settings': {
        'voice_gender': voiceGender.toLowerCase().trim(),
        'accent_locale': accentLocale.trim(),
        'accent_label': (accentLabel ?? accentLocale).trim(),
      },
      'voice_preference': voiceGender.toLowerCase().trim(),
      'voice_accent': accentLocale.trim(),
    });
  }

  static Future<void> clearAymaKnowledge() async {
    await updateProfile({
      'wiki_about_me': '',
      'wiki_context': '',
      'wiki_preferences': '',
      'wiki_matching': '',
      'wiki_profile_structured': '',
      'profile_answers': {},
      'profile_answers_public': {},
      'profile_answers_private': {},
      'profile_answers_sensitive': {},
      'profile_field_visibility': {},
      'raw_user_statements': [],
    });
  }

  static Future<Map<String, dynamic>> correctWikiSection({
    required String section,
    required String feedback,
  }) async {
    final response = await _post('/wiki/correct', {
      'section': section,
      'feedback': feedback,
    });
    if (response.statusCode != 200) {
      throw Exception('Failed to correct wiki: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── Account Deletion ──────────────────────────────────────────────────────

  static Future<void> deleteUserData() async {
    await updateProfile({
      'display_name': '',
      'age': null,
      'gender': '',
      'location_region': '',
      'onboarding_complete': false,
      'matching_paused': false,
      'preboarding_seen': false,
      'photo_order': [],
      'wiki_about_me': '',
      'wiki_context': '',
      'wiki_preferences': '',
      'wiki_matching': '',
      'wiki_profile_structured': '',
      'profile_answers': {},
      'profile_answers_public': {},
      'profile_answers_private': {},
      'profile_answers_sensitive': {},
      'profile_field_visibility': {},
      'raw_user_statements': [],
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_onboardingKey());
    await prefs.remove(_preboardingKey());
  }

  // ── Matches ────────────────────────────────────────────────────────────────

  static Future<List<MatchModel>> getMatches() async {
    final response = await _get('/matches');
    if (response.statusCode != 200) return const [];
    final List<dynamic> list = jsonDecode(response.body);
    return list.map((d) => MatchModel.fromMap(d as Map<String, dynamic>, _uid)).toList();
  }

  static Future<void> updateMatchStatus(String matchId, String status) async {
    final id = int.tryParse(matchId) ?? 0;
    await _post('/matches/$id/status', {'status': status});
  }

  static Future<void> toggleMatchSimulation(String matchId, bool show) async {
    final id = int.tryParse(matchId) ?? 0;
    await _post('/matches/$id/toggle-simulation', {'show_simulation_transcript': show});
  }

  static Future<List<Map<String, dynamic>>> getMatchSimulation(String matchId) async {
    final id = int.tryParse(matchId) ?? 0;
    final response = await _get('/matches/$id/simulation');
    if (response.statusCode != 200) return const [];
    final List<dynamic> list = jsonDecode(response.body);
    return list.cast<Map<String, dynamic>>();
  }

  // ── Notifications ──────────────────────────────────────────────────────────

  static Future<List<NotificationModel>> getNotifications() async {
    final response = await _get('/notifications');
    if (response.statusCode != 200) return const [];
    final List<dynamic> list = jsonDecode(response.body);
    return list.map((d) => NotificationModel.fromMap(d as Map<String, dynamic>)).toList();
  }

  static Stream<List<NotificationModel>> notificationsStream() async* {
    while (true) {
      try {
        final list = await getNotifications();
        yield list;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 8));
    }
  }

  static Future<void> markNotificationRead(String id) async {
    final notifId = int.tryParse(id) ?? 0;
    await _post('/notifications/$notifId/read', {});
  }

  static Future<void> markAllNotificationsRead() async {
    await _post('/notifications/read-all', {});
  }

  // ── Onboarding ─────────────────────────────────────────────────────────────

  static Future<bool> getOnboardingStatus() async {
    // Check local cache first — survives backend cold starts
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_onboardingKey()) == true) return true;

    final p = await getProfile();
    if (p == null) {
      throw Exception('Failed to fetch user profile for onboarding check');
    }
    final complete = inferOnboardingComplete({
      'onboarding_complete': p.onboardingComplete,
      'display_name': p.displayName,
      'gender': p.gender,
      'age': p.age,
      'location_region': p.locationRegion,
      'matching_prefs': p.matchingPrefs,
      'profile_public': p.profilePublic,
      'profile_private': p.profilePrivate,
      'profile_ai_observations': p.profileAnswers,
    });
    if (complete) {
      await prefs.setBool(_onboardingKey(), true);
      if (!p.onboardingComplete) await completeOnboarding();
    }
    return complete;
  }

  static Future<void> markOnboardingCompleteLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey(), true);
  }

  static Future<void> completeOnboarding() async {
    await updateProfile({'onboarding_complete': true});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey(), true);
  }

  static Future<void> markPreboardingSeen() async {
    await updateProfile({'preboarding_seen': true});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preboardingKey(), true);
  }

  static Future<bool> getPreboardingSeen() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_preboardingKey()) == true) return true;
    final response = await _get('/profile');
    if (response.statusCode != 200) return false;
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final seen = (data['preboarding_seen'] as bool?) ?? false;
    if (seen) await prefs.setBool(_preboardingKey(), true);
    return seen;
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
    final response = await _get('/insights');
    if (response.statusCode != 200) return const {};
    final Map<String, dynamic> data = jsonDecode(response.body);
    return data.map((key, value) => MapEntry(key, value.toString()));
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

  // ── Community-specific questions (appended to the global bank) ─────────────
  // These IDs are referenced by CommunityProfile.questionIds but live here
  // so the question bank remains a single source of truth.

  static const List<Map<String, dynamic>> _communityQuestions = [
    // ── Indian Arranged Marriage ───────────────────────────────────────────
    {
      'id': 'mother_tongue',
      'text': 'What language do you speak at home (mother tongue)?',
      'section': 'cultural_identity',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 1,
    },
    {
      'id': 'gotra',
      'text': 'What is your gotra (ancestral lineage)?',
      'section': 'sensitive_attributes',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 30,
    },
    {
      'id': 'manglik_status',
      'text': 'Are you Manglik (Mangal Dosha in your horoscope)?',
      'section': 'sensitive_attributes',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 31,
    },
    {
      'id': 'kundali_match_required',
      'text': 'Is horoscope (kundali) matching required for your marriage?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 32,
    },
    {
      'id': 'nri_status',
      'text': 'Are you an NRI (Non-Resident Indian) or based in India?',
      'section': 'cultural_identity',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 2,
    },
    {
      'id': 'state_of_origin',
      'text': 'Which Indian state are you originally from?',
      'section': 'cultural_identity',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 3,
    },
    {
      'id': 'family_income_band',
      'text': 'What is your approximate family income band (annual)?',
      'section': 'financial_compatibility',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 33,
    },
    {
      'id': 'family_type_preference',
      'text': 'Do you prefer a joint family or nuclear family setup after marriage?',
      'section': 'family_background',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 4,
    },
    {
      'id': 'religious_sect',
      'text': 'What is your religious denomination or sect '
              '(e.g. Sunni/Shia for Muslim; Brahmin/Kshatriya for Hindu)?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 34,
    },
    // ── Muslim Matrimonial ─────────────────────────────────────────────────
    {
      'id': 'hijab_preference',
      'text': 'Do you wear hijab / observe purdah?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 5,
    },
    {
      'id': 'beard_preference',
      'text': 'Do you keep a beard (for men) / prefer a bearded partner?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 6,
    },
    {
      'id': 'prayer_frequency',
      'text': 'How often do you pray (salah)?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 7,
    },
    {
      'id': 'halal_diet_strict',
      'text': 'Do you strictly observe halal dietary requirements?',
      'section': 'physical_lifestyle',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 8,
    },
    {
      'id': 'mahram_required',
      'text': 'Do you require a mahram (chaperone) when meeting a potential spouse?',
      'section': 'values_religion_culture',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 35,
    },
    {
      'id': 'nikah_type',
      'text': 'What type of marriage ceremony do you prefer '
              '(civil + religious, religious only, etc.)?',
      'section': 'intent_readiness',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 9,
    },
    {
      'id': 'polygamy_openness',
      'text': 'Are you open to polygamous marriage arrangements?',
      'section': 'sensitive_attributes',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'deeper',
      'order': 36,
    },
    // ── West African Marriage ──────────────────────────────────────────────
    {
      'id': 'tribe_ethnicity',
      'text': 'What is your tribal or ethnic background?',
      'section': 'cultural_identity',
      'required': false,
      'sensitive_flag': true,
      'priority': 'high',
      'phase': 3,
      'category': 'deeper',
      'order': 37,
    },
    {
      'id': 'lobola_expectation',
      'text': 'What are your thoughts or expectations around bride price / lobola?',
      'section': 'family_background',
      'required': false,
      'sensitive_flag': true,
      'priority': 'medium',
      'phase': 3,
      'category': 'deeper',
      'order': 38,
    },
    {
      'id': 'family_approval_importance',
      'text': 'How important is family approval in your marriage decision?',
      'section': 'family_background',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'deeper',
      'order': 10,
    },
    {
      'id': 'language_spoken',
      'text': 'What language(s) do you primarily speak?',
      'section': 'cultural_identity',
      'required': false,
      'sensitive_flag': false,
      'priority': 'medium',
      'phase': 2,
      'category': 'deeper',
      'order': 11,
    },
    // ── LGBTQ+ Dating ─────────────────────────────────────────────────────
    {
      'id': 'sexual_orientation',
      'text': 'How would you describe your sexual orientation?',
      'section': 'basic_identity',
      'required': false,
      'sensitive_flag': true,
      'priority': 'high',
      'phase': 3,
      'category': 'required',
      'order': 40,
    },
    {
      'id': 'pronouns',
      'text': 'What are your pronouns?',
      'section': 'basic_identity',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'required',
      'order': 12,
    },
    {
      'id': 'transition_status',
      'text': 'Are you comfortable sharing your transition journey or status?',
      'section': 'basic_identity',
      'required': false,
      'sensitive_flag': true,
      'priority': 'low',
      'phase': 3,
      'category': 'deeper',
      'order': 41,
    },
    {
      'id': 'relationship_structure',
      'text': 'What relationship structure works best for you '
              '(monogamous, polyamorous, open, etc.)?',
      'section': 'intent_readiness',
      'required': false,
      'sensitive_flag': false,
      'priority': 'high',
      'phase': 2,
      'category': 'required',
      'order': 13,
    },
  ];

  /// Full question bank — base questions + all community-specific ones.
  static List<Map<String, dynamic>> get allQuestions =>
      [..._northstarQuestions, ..._communityQuestions];

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
    'nri_status': 'core_matchability',
    'state_of_origin': 'core_matchability',
    // intent_and_readiness
    'relationship_intent': 'intent_and_readiness',
    'timeline_for_commitment': 'intent_and_readiness',
    'marital_status': 'intent_and_readiness',
    'relationship_structure': 'intent_and_readiness',
    'nikah_type': 'intent_and_readiness',
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
    'halal_diet_strict': 'lifestyle_compatibility',
    'prayer_frequency': 'lifestyle_compatibility',
    // values_and_family_alignment
    'religion': 'values_and_family_alignment',
    'religious_practice_level': 'values_and_family_alignment',
    'religious_sect': 'values_and_family_alignment',
    'skin_tone': 'values_and_family_alignment',
    'race': 'values_and_family_alignment',
    'caste': 'values_and_family_alignment',
    'sub_caste': 'values_and_family_alignment',
    'gotra': 'values_and_family_alignment',
    'manglik_status': 'values_and_family_alignment',
    'kundali_match_required': 'values_and_family_alignment',
    'family_type': 'values_and_family_alignment',
    'family_type_preference': 'values_and_family_alignment',
    'family_values': 'values_and_family_alignment',
    'family_approval_importance': 'values_and_family_alignment',
    'tribe_ethnicity': 'values_and_family_alignment',
    'mother_tongue': 'values_and_family_alignment',
    'language_spoken': 'values_and_family_alignment',
    'hijab_preference': 'values_and_family_alignment',
    'beard_preference': 'values_and_family_alignment',
    'mahram_required': 'values_and_family_alignment',
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
    'family_income_band': 'depth_and_authenticity',
    'lobola_expectation': 'depth_and_authenticity',
    'polygamy_openness': 'depth_and_authenticity',
    'transition_status': 'depth_and_authenticity',
    'sexual_orientation': 'depth_and_authenticity',
    'pronouns': 'depth_and_authenticity',
  };

  // ── Community Profile helpers ───────────────────────────────────────────────

  /// Returns the [CommunityProfile] config for the given community [id].
  static CommunityProfile getCommunityProfile(String communityId) =>
      CommunityProfiles.forId(communityId);

  /// Returns the ordered, filtered list of questions for a given community.
  /// Questions not in the community's [questionIds] list are excluded.
  static List<Map<String, dynamic>> getQuestionsForCommunity(String communityId) {
    final profile = CommunityProfiles.forId(communityId);
    final orderedIds = profile.questionIds;
    final bank = {for (final q in allQuestions) q['id'] as String: q};
    // Return in the community-defined order, skipping any unknown IDs.
    final result = <Map<String, dynamic>>[];
    for (final id in orderedIds) {
      final q = bank[id];
      if (q != null) result.add(q);
    }
    return result;
  }

  // ── Profile Answers ────────────────────────────────────────────────────────

  /// Reads the user's profile_answers map from the backend.
  static Future<Map<String, dynamic>> getProfileAnswers() async {
    final response = await _get('/profile/answers');
    if (response.statusCode != 200) return const {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Merges a single answer into the backend.
  static Future<void> saveProfileAnswer(
      String questionId, dynamic value) async {
    await _post('/profile/answers', {'field_id': questionId, 'value': value});
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

    final communityId =
        (profileData['community_profile'] as String?) ?? 'dating_standard';

    // Group questions by bucket
    final bucketQuestions = <String, List<Map<String, dynamic>>>{};
    for (final q in getQuestionsForCommunity(communityId)) {
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

        // Check answers map first, then legacy profileData / onboarding fields.
        dynamic val = answers[id];
        if (_isEmptyValue(val)) {
          val = _legacyProfileValue(id, profileData);
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

  static dynamic _legacyProfileValue(
    String questionId,
    Map<String, dynamic> profileData,
  ) {
    const directMap = <String, String>{
      'age': 'age',
      'gender_identity': 'gender',
      'location_city': 'location_region',
      'occupation': 'occupation',
      'height_cm': 'height_cm',
    };
    final directKey = directMap[questionId];
    if (directKey != null) return profileData[directKey];

    if (questionId == 'preferred_age_range') {
      final prefs = profileData['matching_prefs'];
      if (prefs is Map<String, dynamic>) {
        final minAge = prefs['age_min'];
        final maxAge = prefs['age_max'];
        if (minAge != null && maxAge != null) {
          return {'age_min': minAge, 'age_max': maxAge};
        }
      }
    }

    return null;
  }

  /// Reads answers and user doc, returns completeness score 0–100.
  static Future<double> getProfileCompleteness() async {
    final response = await _get('/profile');
    if (response.statusCode != 200) return 0.0;
    final profileData = jsonDecode(response.body) as Map<String, dynamic>;
    final answers = profileData['profile_answers'];
    final answersMap =
        (answers is Map<String, dynamic>) ? answers : <String, dynamic>{};
    return computeProfileCompleteness(answersMap, profileData);
  }

  // ── Questions ─────────────────────────────────────────────────────────────

  // Handled automatically on the server during bootstrap initialization
  static Future<void> initializeQuestions(
      {Set<String> alreadyAnswered = const {}}) async {
    return;
  }

  static Future<void> addFollowupQuestion(String question,
      {String sessionId = ''}) async {
    await _post('/questions/followup', {'question': question});
  }

  static Future<List<Map<String, dynamic>>> getPendingQuestions() async {
    final response = await _get('/questions/pending');
    if (response.statusCode != 200) return const [];
    final List<dynamic> list = jsonDecode(response.body);
    return list.cast<Map<String, dynamic>>();
  }

  /// Marks a question answered in the questions checklist and saves
  /// the value to profile_answers.
  static Future<void> markQuestionAnswered(
      String questionId, dynamic value) async {
    await _post('/questions/$questionId/answered', {});
    await saveProfileAnswer(questionId, value);
  }

  // ── Media ──────────────────────────────────────────────────────────────────

  static Future<void> saveMediaRecord({
    required String photoUrl,
    String caption = '',
  }) async {
    final response = await _post('/media', {'photo_url': photoUrl, 'caption': caption});
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to save media record (${response.statusCode}): ${response.body}');
    }
  }

  static Future<void> deleteMediaByUrl(String photoUrl) async {
    await _delete('/media', {'photo_url': photoUrl});
  }

  static Future<void> updatePhotoOrder(List<String> orderedUrls) async {
    await updateProfile({'photo_order': orderedUrls});
  }

  static Future<void> analyzePhotos(List<String> photoUrls) async {
    try {
      await _post('/profile/analyze-photos', {'photo_urls': photoUrls});
    } catch (_) {}
  }

  // ── Explore ────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> explore({
    String? gender,
    int ageMin = 0,
    int ageMax = 120,
    String query = '',
  }) async {
    final Map<String, String> params = {};
    if (gender != null) params['gender'] = gender;
    params['ageMin'] = ageMin.toString();
    params['ageMax'] = ageMax.toString();
    if (query.isNotEmpty) params['query'] = query;

    final uri = Uri.parse('${Env.bootstrapUrl}/explore').replace(queryParameters: params);
    final token = await _idToken();
    final response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode != 200) return const [];
    final List<dynamic> list = jsonDecode(response.body);
    return list.cast<Map<String, dynamic>>();
  }
}
