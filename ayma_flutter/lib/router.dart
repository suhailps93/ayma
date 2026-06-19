import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/providers.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/chat/chat_screen.dart';
import 'screens/explore/explore_screen.dart';
import 'screens/matches/matches_screen.dart';
import 'screens/notifications/notifications_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/shell/shell_screen.dart';

class _RouterRefreshNotifier extends ChangeNotifier {
  _RouterRefreshNotifier(Ref ref) {
    ref.listen(authSessionProvider, (_, __) => notifyListeners());
    ref.listen(authInitializedProvider, (_, __) => notifyListeners());
    ref.listen(onboardingStatusProvider, (_, __) => notifyListeners());
    ref.listen(preboardingSeenProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterRefreshNotifier(ref);

  final router = GoRouter(
    initialLocation: '/chat',
    refreshListenable: notifier,
    redirect: (context, state) {
      final initialized = ref.read(authInitializedProvider);
      final user = ref.read(authSessionProvider);
      final path = state.matchedLocation;

      if (!initialized) return null;
      if (user == null) return path == '/auth' ? null : '/auth';
      if (path == '/auth') return '/chat';

      final onboarding = ref.read(onboardingStatusProvider);
      if (onboarding.hasValue) {
        final complete = onboarding.value ?? false;
        if (!complete && path != '/onboarding') return '/onboarding';
        if (complete && path == '/onboarding') return '/chat';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/auth',       builder: (_, __) => const AuthScreen()),
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      ShellRoute(
        builder: (context, state, child) => ShellScreen(child: child),
        routes: [
          GoRoute(path: '/chat',          builder: (_, __) => const ChatScreen()),
          GoRoute(path: '/matches',       builder: (_, __) => const MatchesScreen()),
          GoRoute(path: '/explore',       builder: (_, __) => const ExploreScreen()),
          GoRoute(path: '/profile',       builder: (_, __) => const ProfileScreen()),
          GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
          GoRoute(path: '/settings',      builder: (_, __) => const SettingsScreen()),
        ],
      ),
    ],
  );

  ref.onDispose(notifier.dispose);
  return router;
});
