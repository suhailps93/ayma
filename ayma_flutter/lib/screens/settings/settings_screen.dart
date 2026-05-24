import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../theme.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _pauseLoading = false;

  Future<void> _togglePause(bool value) async {
    setState(() => _pauseLoading = true);
    try {
      await updateProfile({'matching_paused': value}, ref);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update: $e')),
        );
      }
    }
    if (mounted) setState(() => _pauseLoading = false);
  }

  Future<void> _deleteAccount() async {
    try {
      await FirebaseAuth.instance.currentUser?.delete();
      await ref.read(authControllerProvider).signOut();
      if (mounted) context.go('/auth');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  void _showExclusionsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AymaColors.bgElev,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _ExclusionsSheet(),
    );
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AymaColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete account',
          style: TextStyle(color: AymaColors.fg, fontSize: 18),
        ),
        content: Text(
          'This permanently deletes your profile, matches, and all data. This cannot be undone.',
          style: TextStyle(color: AymaColors.fgDim, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: AymaColors.fgDim)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteAccount();
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);
    final currentUser = ref.watch(currentUserProvider);
    final profile = profileAsync.valueOrNull;
    final displayName = profile?.displayName ?? 'You';
    final matchingPaused = profile?.matchingPaused ?? false;

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
          children: [
            // Header
            Text(
              'Settings',
              style: AymaFonts.serif(size: 36, color: AymaColors.fg),
            ).animate().fadeIn(duration: 400.ms),
            const SizedBox(height: 28),

            // Account section
            _SectionLabel('Account'),
            _Tile(
              icon: Icons.person_outline_rounded,
              title: displayName,
              subtitle: currentUser?.email ?? '',
              delay: 60,
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.edit_outlined,
              title: 'Edit profile',
              onTap: () => context.go('/profile'),
              delay: 100,
            ),

            const SizedBox(height: 20),

            // Agent section
            _SectionLabel('Ayma'),
            _Tile(
              icon: Icons.memory_rounded,
              title: 'Manage memory',
              subtitle: 'What Ayma knows about you',
              onTap: () => context.go('/insights'),
              delay: 140,
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.tune_rounded,
              title: 'Matching preferences',
              subtitle: 'Update your age range and interests',
              onTap: () => context.go('/profile'),
              delay: 180,
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.block_rounded,
              title: 'Exclusions',
              subtitle: 'People or traits to exclude',
              onTap: _showExclusionsSheet,
              delay: 220,
            ),

            const SizedBox(height: 20),

            // Privacy section
            _SectionLabel('Privacy'),
            _Tile(
              icon: Icons.visibility_off_outlined,
              title: 'Pause matching',
              subtitle: matchingPaused
                  ? 'Your profile is hidden'
                  : 'Temporarily hide your profile',
              trailing: _pauseLoading
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AymaColors.accent),
                    )
                  : Switch(
                      value: matchingPaused,
                      onChanged: _togglePause,
                      activeColor: AymaColors.accent,
                      inactiveThumbColor: AymaColors.fgMute,
                      inactiveTrackColor: AymaColors.lineSoft,
                    ),
              delay: 260,
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.delete_outline_rounded,
              title: 'Delete account',
              titleColor: Colors.redAccent.shade100,
              onTap: _confirmDelete,
              delay: 300,
            ),

            const SizedBox(height: 20),

            // About section
            _SectionLabel('About'),
            _Tile(
              icon: Icons.info_outline_rounded,
              title: 'Version',
              subtitle: '1.0.0',
              delay: 340,
            ),

            const SizedBox(height: 20),

            _SignOutTile(delay: 380),
          ],
        ),
      ),
    );
  }
}

// ── Exclusions sheet ──────────────────────────────────────────────────────────

class _ExclusionsSheet extends ConsumerStatefulWidget {
  const _ExclusionsSheet();

  @override
  ConsumerState<_ExclusionsSheet> createState() => _ExclusionsSheetState();
}

class _ExclusionsSheetState extends ConsumerState<_ExclusionsSheet> {
  final _ctrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _ctrl.text.trim();
    setState(() => _saving = true);
    try {
      final profile = ref.read(profileProvider).valueOrNull;
      final currentPrefs = Map<String, dynamic>.from(profile?.matchingPrefs ?? const {});
      if (text.isEmpty) {
        currentPrefs.remove('exclusions');
      } else {
        currentPrefs['exclusions'] = text;
      }
      await updateProfile({'matching_prefs': currentPrefs}, ref);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).valueOrNull;
    if (_ctrl.text.isEmpty && profile != null) {
      final existing = (profile.matchingPrefs['exclusions'] as String?) ?? '';
      if (existing.isNotEmpty) _ctrl.text = existing;
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 24,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Exclusions', style: AymaFonts.serif(size: 22, color: AymaColors.fg)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Icon(Icons.close_rounded, color: AymaColors.fgMute, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Describe people or traits you\'d like Ayma to avoid in matches.',
            style: TextStyle(color: AymaColors.fgDim, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              color: AymaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AymaColors.lineSoft, width: 0.5),
            ),
            child: TextField(
              controller: _ctrl,
              maxLines: 4,
              style: TextStyle(color: AymaColors.fg, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'e.g. smokers, long-distance, under 25',
                hintStyle: TextStyle(color: AymaColors.fgMute, fontSize: 13),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _saving ? null : _save,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: AymaColors.fg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: _saving
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black),
                      )
                    : const Text(
                        'Save',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
    ),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: titleColor ?? AymaColors.fgDim),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor ?? AymaColors.fg,
                      fontSize: 14,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(color: AymaColors.fgMute, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded, size: 16, color: AymaColors.fgMute),
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
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.logout_rounded, size: 16, color: Colors.redAccent.shade100),
            const SizedBox(width: 8),
            Text(
              'Sign out',
              style: TextStyle(
                color: Colors.redAccent.shade100,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 300.ms);
  }
}
