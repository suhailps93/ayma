import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../theme.dart';

class ShellScreen extends ConsumerWidget {
  final Widget child;
  const ShellScreen({super.key, required this.child});

  static const _tabs = [
    (path: '/chat',          icon: Icons.graphic_eq_rounded,    label: 'Talk'),
    (path: '/matches',       icon: Icons.people_outline_rounded, label: 'Matches'),
    (path: '/profile',       icon: Icons.person_outline_rounded, label: 'Profile'),
    (path: '/notifications', icon: Icons.notifications_none_rounded, label: 'Alerts'),
    (path: '/settings',      icon: Icons.settings_outlined,     label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final unread = ref.watch(notificationsProvider.select(
        (ns) => ns.where((n) => !n.read).length));

    int selectedIndex = _tabs.indexWhere((t) => location.startsWith(t.path));
    if (selectedIndex == -1) selectedIndex = 0;

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AymaColors.surface,
          border: Border(top: BorderSide(color: AymaColors.border, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 60,
            child: Row(
              children: List.generate(_tabs.length, (i) {
                final tab = _tabs[i];
                final active = i == selectedIndex;
                final isNotif = tab.path == '/notifications';

                return Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => context.go(tab.path),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Icon(
                                tab.icon,
                                size: 22,
                                color: active
                                    ? AymaColors.accent
                                    : AymaColors.textTertiary,
                              ),
                              if (isNotif && unread > 0)
                                Positioned(
                                  top: -4,
                                  right: -6,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: AymaColors.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        unread > 9 ? '9+' : '$unread',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 8,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            tab.label,
                            style: TextStyle(
                              fontSize: 10,
                              color: active
                                  ? AymaColors.accent
                                  : AymaColors.textTertiary,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
