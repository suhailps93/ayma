import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/notification_model.dart';
import '../../providers/providers.dart';
import '../../theme.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifs   = ref.watch(notificationsProvider);
    final notifier = ref.read(notificationsProvider.notifier);
    final unread   = notifs.where((n) => !n.read).length;

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        unread > 0 ? '$unread unread' : 'Up to date',
                        style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
                      ).animate().fadeIn(duration: 300.ms),
                      const Spacer(),
                      if (unread > 0)
                        GestureDetector(
                          onTap: notifier.markAllRead,
                          child: Text(
                            'Mark all read',
                            style: AymaFonts.mono(size: 9, color: AymaColors.accent),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Signals',
                    style: AymaFonts.serif(size: 36, color: AymaColors.fg),
                  ).animate(delay: 60.ms).fadeIn(duration: 400.ms),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            Expanded(
              child: notifs.isEmpty
                  ? _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: notifs.length,
                      itemBuilder: (_, i) => _NotifCard(
                        notif: notifs[i],
                        delay: i * 50,
                        onTap: () {
                          notifier.markRead(notifs[i].id);
                          _navigate(context, notifs[i]);
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

void _navigate(BuildContext context, NotificationModel n) {
  switch (n.type) {
    case NotificationType.newMatch:
      context.go('/matches');
    case NotificationType.agentUpdate:
      context.go('/insights');
    case NotificationType.profileSuggestion:
      context.go('/profile');
    case NotificationType.system:
      break;
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.notifications_none_rounded,
            size: 48, color: AymaColors.textTertiary),
        const SizedBox(height: 16),
        Text('All caught up',
            style: TextStyle(color: AymaColors.textPrimary, fontSize: 16,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text('You have no notifications.',
            style: TextStyle(color: AymaColors.textSecondary, fontSize: 13)),
      ],
    ).animate().fadeIn(duration: 400.ms),
  );
}

class _NotifCard extends StatelessWidget {
  final NotificationModel notif;
  final int delay;
  final VoidCallback onTap;
  const _NotifCard({required this.notif, required this.delay, required this.onTap});

  IconData get _icon {
    switch (notif.type) {
      case NotificationType.newMatch:         return Icons.favorite_border_rounded;
      case NotificationType.agentUpdate:      return Icons.auto_awesome;
      case NotificationType.profileSuggestion: return Icons.edit_note_rounded;
      case NotificationType.system:           return Icons.info_outline_rounded;
    }
  }

  Color get _iconColor {
    switch (notif.type) {
      case NotificationType.newMatch:         return Colors.pink.shade300;
      case NotificationType.agentUpdate:      return AymaColors.accent;
      case NotificationType.profileSuggestion: return Colors.green.shade400;
      case NotificationType.system:           return AymaColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: notif.read
                ? AymaColors.lineSoft
                : AymaColors.accent.withValues(alpha: 0.25),
            width: 0.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: _iconColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(_icon, color: _iconColor, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(notif.title,
                            style: TextStyle(
                                color: AymaColors.textPrimary,
                                fontWeight: notif.read
                                    ? FontWeight.w400
                                    : FontWeight.w600,
                                fontSize: 14)),
                      ),
                      if (!notif.read)
                        Container(
                          width: 6, height: 6,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AymaColors.accent),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(notif.body,
                      style: TextStyle(
                          color: AymaColors.textSecondary, fontSize: 13,
                          height: 1.4)),
                  const SizedBox(height: 6),
                  Text(_timeAgo(notif.createdAt),
                      style: TextStyle(
                          color: AymaColors.textTertiary, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 300.ms).slideX(begin: 0.03, end: 0);
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }
}
