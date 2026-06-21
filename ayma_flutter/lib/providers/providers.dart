import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/auth_session.dart';
import '../models/match_model.dart';
import '../models/notification_model.dart';
import '../models/profile.dart';
import '../services/audio_service.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/backend_service.dart';

// ── Auth ──────────────────────────────────────────────────────────────────────

final authControllerProvider = ChangeNotifierProvider<AuthService>((ref) {
  final service = AuthService(ref);
  ref.onDispose(service.dispose);
  return service;
});

// Emits the Firebase User (null when signed out). Used by router.
final firebaseUserProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

// Registers the device FCM token with the backend whenever the user signs in.
// Web and environments where FCM is unavailable are silently skipped.
final fcmRegistrationProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<User?>>(firebaseUserProvider, (_, next) {
    next.whenData((user) async {
      if (user == null || kIsWeb) return;
      try {
        final messaging = FirebaseMessaging.instance;
        final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
        if (settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional) {
          final token = await messaging.getToken();
          if (token != null) {
            await BackendService.saveDeviceToken(token);
          }
          // Refresh and re-register when the token rotates
          messaging.onTokenRefresh.listen((newToken) async {
            try {
              await BackendService.saveDeviceToken(newToken);
            } catch (_) {}
          });
        }
      } catch (_) {
        // FCM unavailable on this platform/build — ignore silently
      }
    });
  });
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
  return ApiService.getProfile();
});

final publicProfileProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, userId) async {
  if (userId.isEmpty) return null;
  return ApiService.getPublicProfile(userId);
});

// ── Matches ───────────────────────────────────────────────────────────────────

final matchesProvider = FutureProvider<List<MatchModel>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  return ApiService.getMatches();
});

final userProfileByIdProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, userId) async {
  if (userId.isEmpty) return null;
  return ApiService.getPublicProfile(userId);
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
    _sub = ApiService.notificationsStream().listen(
      (list) => state = list,
      onError: (e) {
        debugPrint('Notifications stream error: $e');
        state = const [];
      },
    );
  }

  void add(NotificationModel n) => state = [n, ...state];

  Future<void> markRead(String id) async {
    state = [for (final n in state) if (n.id == id) n.copyWith(read: true) else n];
    await ApiService.markNotificationRead(id);
  }

  Future<void> markAllRead() async {
    state = state.map((n) => n.copyWith(read: true)).toList();
    await ApiService.markAllNotificationsRead();
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
  return ApiService.getOnboardingStatus();
});

final preboardingSeenProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return false;
  return ApiService.getPreboardingSeen();
});

// ── Insights ──────────────────────────────────────────────────────────────────

final insightsProvider = FutureProvider<Map<String, String>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return {};
  return ApiService.getInsights();
});

// ── Profile Answers ───────────────────────────────────────────────────────────

final profileAnswersProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return {};
  return ApiService.getProfileAnswers();
});

// ── Profile Completeness ──────────────────────────────────────────────────────

final profileCompletenessProvider = FutureProvider<double>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return 0.0;
  return ApiService.getProfileCompleteness();
});

// ── Match actions ─────────────────────────────────────────────────────────────

Future<void> acceptMatch(String matchId, WidgetRef ref) async {
  await ApiService.updateMatchStatus(matchId, 'accepted');
  ref.invalidate(matchesProvider);
}

Future<void> rejectMatch(String matchId, WidgetRef ref) async {
  await ApiService.updateMatchStatus(matchId, 'rejected');
  ref.invalidate(matchesProvider);
}

Future<void> runVibeCheck(String matchId, WidgetRef ref) async {
  await BackendService.vibeCheck(matchId);
  ref.invalidate(matchesProvider);
}

Future<void> toggleMatchSimulation(String matchId, bool show, WidgetRef ref) async {
  await ApiService.toggleMatchSimulation(matchId, show);
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
    this.ageMin = 0,
    this.ageMax = 120,
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
  final people = await ApiService.explore(
    gender: filters.gender,
    ageMin: filters.ageMin,
    ageMax: filters.ageMax,
    query: filters.query,
  );
  return {'people': people, 'prompts': []};
});

// ── Profile update ────────────────────────────────────────────────────────────

Future<void> updateProfile(Map<String, dynamic> fields, WidgetRef ref) async {
  await ApiService.updateProfile(fields);
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

// ── Theme Mode ────────────────────────────────────────────────────────────────

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.dark) {
    _load();
  }

  static const _key = 'ayma_theme_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved == 'light') state = ThemeMode.light;
  }

  Future<void> toggle() async {
    final next = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, next == ThemeMode.light ? 'light' : 'dark');
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode == ThemeMode.light ? 'light' : 'dark');
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(),
);

// ── Network connectivity ──────────────────────────────────────────────────────

final networkConnectedProvider = StreamProvider<bool>((ref) {
  return Connectivity()
      .onConnectivityChanged
      .map((results) => results.any((r) => r != ConnectivityResult.none))
      .distinct();
});
