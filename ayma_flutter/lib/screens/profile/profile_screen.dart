import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/profile.dart';
import '../../providers/providers.dart';
import '../../services/backend_service.dart';
import '../../theme.dart';
import '../../widgets/ayma_button.dart';
import '../../widgets/ayma_text_field.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _editing      = false;
  bool _saving       = false;
  final _bioCtrl     = TextEditingController();
  final _notesCtrl   = TextEditingController();

  void _startEdit(UserProfile profile) {
    _bioCtrl.text   = profile.profilePublic  ?? '';
    _notesCtrl.text = profile.profilePrivate ?? '';
    setState(() => _editing = true);
  }

  Future<void> _save(UserProfile profile) async {
    setState(() => _saving = true);
    try {
      await BackendService.post('/api/profile', {
        'profile_public':   _bioCtrl.text.trim(),
        'profile_private':  _notesCtrl.text.trim(),
      });
      ref.invalidate(profileProvider);
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  void dispose() {
    _bioCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: profileAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (e, _) => Center(
              child: Text('Error loading profile',
                  style: TextStyle(color: AymaColors.textSecondary))),
          data: (profile) {
            if (profile == null) {
              return Center(
                  child: Text('No profile found',
                      style: TextStyle(color: AymaColors.textSecondary)));
            }
            return _editing
                ? _EditView(
                    profile: profile,
                    bioCtrl: _bioCtrl,
                    notesCtrl: _notesCtrl,
                    saving: _saving,
                    onSave: () => _save(profile),
                    onCancel: () => setState(() => _editing = false),
                  )
                : _ReadView(profile: profile, onEdit: () => _startEdit(profile));
          },
        ),
      ),
    );
  }
}

class _ReadView extends StatelessWidget {
  final UserProfile profile;
  final VoidCallback onEdit;
  const _ReadView({required this.profile, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Text('Profile',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AymaColors.textPrimary,
                    fontWeight: FontWeight.w600))
                .animate().fadeIn(duration: 400.ms),
            const Spacer(),
            IconButton(
              onPressed: onEdit,
              icon: Icon(Icons.edit_outlined, color: AymaColors.textSecondary, size: 20),
              tooltip: 'Edit profile',
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Avatar + name
        Center(
          child: Column(
            children: [
              Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AymaColors.accent.withValues(alpha: 0.12),
                  border: Border.all(color: AymaColors.accent.withValues(alpha: 0.3), width: 1.5),
                ),
                child: Center(
                  child: Text(
                    profile.displayName.isNotEmpty
                        ? profile.displayName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                        color: AymaColors.accent,
                        fontSize: 32,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                profile.displayName.isNotEmpty ? profile.displayName : 'You',
                style: TextStyle(
                    color: AymaColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600),
              ),
              if (profile.age != null || profile.locationRegion != null) ...[
                const SizedBox(height: 4),
                Text(
                  [
                    if (profile.age != null) '${profile.age}',
                    if (profile.gender != null) profile.gender!,
                    if (profile.locationRegion != null) profile.locationRegion!,
                  ].join(' · '),
                  style: TextStyle(color: AymaColors.textSecondary, fontSize: 13),
                ),
              ],
            ],
          ),
        ).animate(delay: 100.ms).fadeIn(duration: 400.ms),

        const SizedBox(height: 28),

        // Public bio
        _Section(
          title: 'Public profile',
          badge: !profile.profilePublicLocked ? 'AI written' : 'Edited',
          badgeColor: !profile.profilePublicLocked
              ? AymaColors.accent
              : Colors.green.shade400,
          child: Text(
            profile.profilePublic?.isNotEmpty == true
                ? profile.profilePublic!
                : 'No public bio yet. Talk to Ayma to build your profile.',
            style: TextStyle(
                color: profile.profilePublic?.isNotEmpty == true
                    ? AymaColors.textPrimary
                    : AymaColors.textTertiary,
                fontSize: 14,
                height: 1.6),
          ),
        ).animate(delay: 180.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

        const SizedBox(height: 16),

        // Private notes
        _Section(
          title: 'Private notes',
          subtitle: 'Only visible to you — Ayma uses this to understand you better.',
          child: Text(
            profile.profilePrivate?.isNotEmpty == true
                ? profile.profilePrivate!
                : 'No private notes yet.',
            style: TextStyle(
                color: profile.profilePrivate?.isNotEmpty == true
                    ? AymaColors.textPrimary
                    : AymaColors.textTertiary,
                fontSize: 14,
                height: 1.6),
          ),
        ).animate(delay: 240.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

        if (profile.matchingPrefs.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(
            title: 'Matching preferences',
            child: _PrefsView(prefs: profile.matchingPrefs),
          ).animate(delay: 300.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),
        ],
      ],
    );
  }
}

class _EditView extends StatelessWidget {
  final UserProfile profile;
  final TextEditingController bioCtrl, notesCtrl;
  final bool saving;
  final VoidCallback onSave, onCancel;
  const _EditView({
    required this.profile, required this.bioCtrl, required this.notesCtrl,
    required this.saving, required this.onSave, required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onCancel,
              icon: Icon(Icons.arrow_back_rounded, color: AymaColors.textSecondary),
            ),
            Text('Edit Profile',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AymaColors.textPrimary, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 24),
        Text('Public bio', style: TextStyle(color: AymaColors.textSecondary,
            fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        AymaTextField(controller: bioCtrl, label: 'Bio', maxLines: 5),
        const SizedBox(height: 20),
        Text('Private notes', style: TextStyle(color: AymaColors.textSecondary,
            fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        AymaTextField(controller: notesCtrl, label: 'Notes (only you see this)', maxLines: 5),
        const SizedBox(height: 28),
        AymaButton(label: 'Save changes', loading: saving, onPressed: onSave),
        const SizedBox(height: 12),
        AymaButton(label: 'Cancel', outlined: true, onPressed: onCancel),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? badge;
  final Color? badgeColor;
  final Widget child;
  const _Section({
    required this.title, this.subtitle, this.badge,
    this.badgeColor, required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AymaColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AymaColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: TextStyle(
                  color: AymaColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5)),
              if (badge != null) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (badgeColor ?? AymaColors.accent).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(badge!, style: TextStyle(
                      color: badgeColor ?? AymaColors.accent,
                      fontSize: 10, fontWeight: FontWeight.w600)),
                ),
              ],
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: TextStyle(color: AymaColors.textTertiary, fontSize: 11)),
          ],
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _PrefsView extends StatelessWidget {
  final Map<String, dynamic> prefs;
  const _PrefsView({required this.prefs});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: [
        if (prefs['interested_in'] != null)
          _Chip('Interested in: ${prefs['interested_in']}'),
        if (prefs['age_min'] != null && prefs['age_max'] != null)
          _Chip('Age: ${prefs['age_min']}–${prefs['age_max']}'),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip(this.label);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: AymaColors.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AymaColors.border),
    ),
    child: Text(label, style: TextStyle(color: AymaColors.textSecondary, fontSize: 12)),
  );
}
