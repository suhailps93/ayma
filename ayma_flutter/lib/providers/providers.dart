import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_session.dart';
import '../models/match_model.dart';
import '../models/notification_model.dart';
import 'dart:async';
import '../models/profile.dart';
import '../services/audio_service.dart';
import '../services/auth_service.dart';
import '../services/backend_service.dart';

// ── Auth ──────────────────────────────────────────────────────────────────────

final authControllerProvider = ChangeNotifierProvider<AuthService>((ref) {
  final service = AuthService();
  ref.onDispose(service.dispose);
  return service;
});

final authSessionProvider = Provider<AuthSession?>((ref) {
  return ref.watch(authControllerProvider).session;
});

final authInitializedProvider = Provider<bool>((ref) {
  return ref.watch(authControllerProvider).initialized;
});

final currentUserProvider = Provider<AuthUser?>((ref) {
  return ref.watch(authControllerProvider).currentUser;
});

// ── Profile ───────────────────────────────────────────────────────────────────

final profileProvider = FutureProvider<UserProfile?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  final res = await BackendService.get('/api/profile') as Map<String, dynamic>;
  return UserProfile.fromMap(res);
});

// ── Matches ───────────────────────────────────────────────────────────────────

final matchesProvider = FutureProvider<List<MatchModel>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final res = await BackendService.get('/api/matches') as List<dynamic>;
  return res
      .map((m) => MatchModel.fromMap(m as Map<String, dynamic>, user.id))
      .toList();
});

// ── Notifications ─────────────────────────────────────────────────────────────

final notificationsProvider =
    StateNotifierProvider<NotificationsNotifier, List<NotificationModel>>(
  (ref) {
    final notifier = NotificationsNotifier(ref);
    ref.listen(currentUserProvider, (_, __) {
      unawaited(notifier.reload());
    });
    return notifier;
  },
);

class NotificationsNotifier extends StateNotifier<List<NotificationModel>> {
  NotificationsNotifier(this._ref) : super(const []) {
    unawaited(reload());
  }

  final Ref _ref;

  Future<void> reload() async {
    final user = _ref.read(currentUserProvider);
    if (user == null) {
      state = const [];
      return;
    }
    final res = await BackendService.get('/api/notifications') as List<dynamic>;
    state = res
        .map((m) => NotificationModel.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  void add(NotificationModel n) {
    state = [n, ...state];
  }

  Future<void> markRead(String id) async {
    state = [
      for (final n in state)
        if (n.id == id) n.copyWith(read: true) else n,
    ];
    await BackendService.post('/api/notifications/$id/read', const {});
  }

  Future<void> markAllRead() async {
    state = state.map((n) => n.copyWith(read: true)).toList();
    await BackendService.post('/api/notifications/read-all', const {});
  }

  int get unreadCount => state.where((n) => !n.read).length;
}

// ── Onboarding ────────────────────────────────────────────────────────────────

final onboardingStatusProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return false;
  final res =
      await BackendService.get('/api/onboarding-status') as Map<String, dynamic>;
  return (res['onboarding_complete'] as bool?) ?? false;
});

// ── Insights (Your Story / wiki pages) ───────────────────────────────────────

final insightsProvider = FutureProvider<Map<String, String>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return {};
  final res = await BackendService.get('/api/insights') as Map<String, dynamic>;
  return res.map((k, v) => MapEntry(k, (v as String?) ?? ''));
});

// ── Match actions ─────────────────────────────────────────────────────────────

/// Accepts a match by id; invalidates [matchesProvider] on success.
Future<void> acceptMatch(String matchId, WidgetRef ref) async {
  await BackendService.post('/api/matches/$matchId/accept', {});
  ref.invalidate(matchesProvider);
}

/// Rejects a match by id; invalidates [matchesProvider] on success.
Future<void> rejectMatch(String matchId, WidgetRef ref) async {
  await BackendService.post('/api/matches/$matchId/reject', {});
  ref.invalidate(matchesProvider);
}

// ── Explore ───────────────────────────────────────────────────────────────────

class ExploreFilters {
  final String tab;       // 'people' | 'prompts'
  final String? gender;
  final int ageMin;
  final int ageMax;
  final int radiusKm;
  final String query;

  const ExploreFilters({
    this.tab = 'people',
    this.gender,
    this.ageMin = 18,
    this.ageMax = 60,
    this.radiusKm = 50,
    this.query = '',
  });

  ExploreFilters copyWith({
    String? tab,
    Object? gender = _sentinel,
    int? ageMin,
    int? ageMax,
    int? radiusKm,
    String? query,
  }) =>
      ExploreFilters(
        tab:      tab      ?? this.tab,
        gender:   gender == _sentinel ? this.gender : gender as String?,
        ageMin:   ageMin   ?? this.ageMin,
        ageMax:   ageMax   ?? this.ageMax,
        radiusKm: radiusKm ?? this.radiusKm,
        query:    query    ?? this.query,
      );
}

const _sentinel = Object();

final exploreFiltersProvider =
    StateProvider<ExploreFilters>((_) => const ExploreFilters());

final exploreProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return {'people': [], 'prompts': []};
  final filters = ref.watch(exploreFiltersProvider);
  final params = <String, dynamic>{
    'tab':       filters.tab,
    'age_min':   filters.ageMin,
    'age_max':   filters.ageMax,
    'radius_km': filters.radiusKm,
    if (filters.gender != null) 'gender': filters.gender,
    if (filters.query.isNotEmpty) 'query': filters.query,
  };
  try {
    final res = await BackendService.get('/api/explore', params) as Map<String, dynamic>;
    return res;
  } catch (_) {
    // Endpoint may not exist yet — return empty gracefully
    return {'people': [], 'prompts': []};
  }
});

// ── Profile update actions ─────────────────────────────────────────────────────

/// Posts a partial profile update and invalidates [profileProvider].
Future<void> updateProfile(Map<String, dynamic> fields, WidgetRef ref) async {
  await BackendService.post('/api/profile', fields);
  ref.invalidate(profileProvider);
}

// ── Audio Service ─────────────────────────────────────────────────────────────

final audioServiceProvider = ChangeNotifierProvider<AymaAudioService>((ref) {
  final svc = AymaAudioService();
  ref.onDispose(svc.dispose);
  return svc;
});
