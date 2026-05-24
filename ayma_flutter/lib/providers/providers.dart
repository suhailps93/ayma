import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_session.dart';
import '../models/match_model.dart';
import '../models/notification_model.dart';
import '../models/profile.dart';
import '../services/audio_service.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';

// ── Auth ──────────────────────────────────────────────────────────────────────

final authControllerProvider = ChangeNotifierProvider<AuthService>((ref) {
  final service = AuthService();
  ref.onDispose(service.dispose);
  return service;
});

// Emits the Firebase User (null when signed out). Used by router.
final firebaseUserProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

// Convenience — maps Firebase User → AuthUser for the rest of the app.
final currentUserProvider = Provider<AuthUser?>((ref) {
  final asyncUser = ref.watch(firebaseUserProvider);
  return asyncUser.when(
    data: (u) => u == null ? null : AuthUser(id: u.uid, email: u.email),
    loading: () => null,
    error: (_, __) => null,
  );
});

// True once Firebase has resolved the initial auth state.
final authInitializedProvider = Provider<bool>((ref) {
  return !ref.watch(firebaseUserProvider).isLoading;
});

// Keep authSessionProvider as an alias so router.dart compiles unchanged.
final authSessionProvider = Provider<AuthUser?>((ref) {
  return ref.watch(currentUserProvider);
});

// ── Profile ───────────────────────────────────────────────────────────────────

final profileProvider = FutureProvider<UserProfile?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  return FirestoreService.getProfile();
});

final publicProfileProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, userId) async {
  if (userId.isEmpty) return null;
  return FirestoreService.getPublicProfile(userId);
});

// ── Matches ───────────────────────────────────────────────────────────────────

final matchesProvider = FutureProvider<List<MatchModel>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  return FirestoreService.getMatches();
});

// ── Notifications ─────────────────────────────────────────────────────────────

final notificationsProvider =
    StateNotifierProvider<NotificationsNotifier, List<NotificationModel>>((ref) {
  final notifier = NotificationsNotifier(ref);
  ref.listen(currentUserProvider, (_, user) {
    if (user != null) unawaited(notifier.reload());
  });
  return notifier;
});

class NotificationsNotifier extends StateNotifier<List<NotificationModel>> {
  NotificationsNotifier(this._ref) : super(const []) {
    unawaited(reload());
  }

  final Ref _ref;
  StreamSubscription? _sub;

  Future<void> reload() async {
    final user = _ref.read(currentUserProvider);
    if (user == null) {
      state = const [];
      return;
    }
    _sub?.cancel();
    _sub = FirestoreService.notificationsStream().listen((list) => state = list);
  }

  void add(NotificationModel n) => state = [n, ...state];

  Future<void> markRead(String id) async {
    state = [for (final n in state) if (n.id == id) n.copyWith(read: true) else n];
    await FirestoreService.markNotificationRead(id);
  }

  Future<void> markAllRead() async {
    state = state.map((n) => n.copyWith(read: true)).toList();
    await FirestoreService.markAllNotificationsRead();
  }

  int get unreadCount => state.where((n) => !n.read).length;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ── Onboarding ────────────────────────────────────────────────────────────────

final onboardingStatusProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return false;
  return FirestoreService.getOnboardingStatus();
});

// ── Insights ──────────────────────────────────────────────────────────────────

final insightsProvider = FutureProvider<Map<String, String>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return {};
  return FirestoreService.getInsights();
});

// ── Match actions ─────────────────────────────────────────────────────────────

Future<void> acceptMatch(String matchId, WidgetRef ref) async {
  await FirestoreService.updateMatchStatus(matchId, 'accepted');
  ref.invalidate(matchesProvider);
}

Future<void> rejectMatch(String matchId, WidgetRef ref) async {
  await FirestoreService.updateMatchStatus(matchId, 'rejected');
  ref.invalidate(matchesProvider);
}

// ── Explore ───────────────────────────────────────────────────────────────────

class ExploreFilters {
  final String tab;
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
        tab: tab ?? this.tab,
        gender: gender == _sentinel ? this.gender : gender as String?,
        ageMin: ageMin ?? this.ageMin,
        ageMax: ageMax ?? this.ageMax,
        radiusKm: radiusKm ?? this.radiusKm,
        query: query ?? this.query,
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
  final people = await FirestoreService.explore(
    gender: filters.gender,
    ageMin: filters.ageMin,
    ageMax: filters.ageMax,
    query: filters.query,
  );
  return {'people': people, 'prompts': []};
});

// ── Profile update ────────────────────────────────────────────────────────────

Future<void> updateProfile(Map<String, dynamic> fields, WidgetRef ref) async {
  await FirestoreService.updateProfile(fields);
  ref.invalidate(profileProvider);
  final user = ref.read(currentUserProvider);
  if (user != null) {
    ref.invalidate(publicProfileProvider(user.id));
  }
}

// ── Audio Service ─────────────────────────────────────────────────────────────

final audioServiceProvider = ChangeNotifierProvider<AymaAudioService>((ref) {
  final svc = AymaAudioService();
  ref.onDispose(svc.dispose);
  return svc;
});
