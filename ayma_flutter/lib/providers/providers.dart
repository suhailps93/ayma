import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_session.dart';
import '../models/match_model.dart';
import '../models/notification_model.dart';
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
  (ref) => NotificationsNotifier(),
);

class NotificationsNotifier extends StateNotifier<List<NotificationModel>> {
  NotificationsNotifier() : super(const []);

  void add(NotificationModel n) {
    state = [n, ...state];
  }

  void markRead(String id) {
    state = [
      for (final n in state)
        if (n.id == id) n.copyWith(read: true) else n,
    ];
  }

  void markAllRead() {
    state = state.map((n) => n.copyWith(read: true)).toList();
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

// ── Audio Service ─────────────────────────────────────────────────────────────

final audioServiceProvider = ChangeNotifierProvider<AymaAudioService>((ref) {
  final svc = AymaAudioService();
  ref.onDispose(svc.dispose);
  return svc;
});
