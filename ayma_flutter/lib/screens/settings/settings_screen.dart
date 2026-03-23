import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileProvider);
    final currentUser = ref.watch(currentUserProvider);
    final displayName = profileAsync.valueOrNull?.displayName ?? 'You';

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Settings',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AymaColors.textPrimary,
                    fontWeight: FontWeight.w600))
                .animate().fadeIn(duration: 400.ms),

            const SizedBox(height: 24),

            // Account section
            _SectionLabel('Account'),
            _Tile(
              icon: Icons.person_outline_rounded,
              title: displayName,
              subtitle: currentUser?.email ?? '',
              delay: 100,
            ),

            const SizedBox(height: 4),

            _Tile(
              icon: Icons.edit_outlined,
              title: 'Edit profile',
              onTap: () => context.go('/profile'),
              delay: 150,
            ),

            const SizedBox(height: 20),

            // Agent section
            _SectionLabel('Ayma'),

            _Tile(
              icon: Icons.memory_rounded,
              title: 'Manage memory',
              subtitle: 'What Ayma knows about you',
              onTap: () {},
              delay: 200,
            ),

            _Tile(
              icon: Icons.tune_rounded,
              title: 'Matching preferences',
              subtitle: 'Update your age range and interests',
              onTap: () => context.go('/profile'),
              delay: 240,
            ),

            _Tile(
              icon: Icons.block_rounded,
              title: 'Exclusions',
              subtitle: 'People or traits to exclude',
              onTap: () {},
              delay: 280,
            ),

            const SizedBox(height: 20),

            // Privacy section
            _SectionLabel('Privacy'),

            _Tile(
              icon: Icons.visibility_off_outlined,
              title: 'Pause matching',
              subtitle: 'Temporarily hide your profile',
              trailing: Switch(
                value: false,
                onChanged: (_) {},
                activeColor: AymaColors.accent,
              ),
              delay: 320,
            ),

            _Tile(
              icon: Icons.delete_outline_rounded,
              title: 'Delete account',
              titleColor: Colors.redAccent.shade100,
              onTap: () => _confirmDelete(context),
              delay: 360,
            ),

            const SizedBox(height: 20),

            // About section
            _SectionLabel('About'),

            _Tile(
              icon: Icons.info_outline_rounded,
              title: 'Version',
              subtitle: '1.0.0',
              delay: 400,
            ),

            const SizedBox(height: 20),

            // Sign out
            _SignOutTile(delay: 450),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AymaColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete account',
            style: TextStyle(color: AymaColors.textPrimary)),
        content: Text(
            'This will permanently delete your profile, matches, and all data. This cannot be undone.',
            style: TextStyle(color: AymaColors.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: AymaColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(),
        style: TextStyle(
            color: AymaColors.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8)),
  );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? titleColor;
  final Widget? trailing;
  final int delay;

  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.titleColor,
    this.trailing,
    this.delay = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AymaColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AymaColors.border),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 20,
                color: titleColor ?? AymaColors.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: titleColor ?? AymaColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style: TextStyle(
                            color: AymaColors.textTertiary, fontSize: 12)),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: AymaColors.textTertiary),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 300.ms).slideX(begin: 0.03, end: 0);
  }
}

class _SignOutTile extends ConsumerWidget {
  final int delay;
  const _SignOutTile({required this.delay});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () async {
        await ref.read(authControllerProvider).signOut();
        if (context.mounted) context.go('/auth');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AymaColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AymaColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent.shade100),
            const SizedBox(width: 8),
            Text('Sign out',
                style: TextStyle(
                    color: Colors.redAccent.shade100,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 300.ms);
  }
}
