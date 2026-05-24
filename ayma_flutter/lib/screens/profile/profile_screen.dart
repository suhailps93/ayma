import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/profile.dart';
import '../../providers/providers.dart';
import '../../services/backend_service.dart';
import '../../services/firestore_service.dart';
import '../../theme.dart';
import '../../widgets/ayma_button.dart';
import '../../widgets/ayma_text_field.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _editing        = false;
  bool _saving         = false;
  bool _uploadingPhoto = false;
  final _bioCtrl       = TextEditingController();
  final _notesCtrl     = TextEditingController();
  final _agentNameCtrl = TextEditingController();
  String? _voicePref;
  bool? _matchingPaused;
  final ImagePicker _imagePicker = ImagePicker();

  void _startEdit(UserProfile profile) {
    _bioCtrl.text        = profile.profilePublic  ?? '';
    _notesCtrl.text      = profile.profilePrivate ?? '';
    _agentNameCtrl.text  = profile.agentName;
    _voicePref           = profile.voicePreference;
    _matchingPaused      = profile.matchingPaused;
    setState(() => _editing = true);
  }

  Future<void> _save(UserProfile profile) async {
    setState(() => _saving = true);
    try {
      await FirestoreService.updateProfile({
        'profile_public':   _bioCtrl.text.trim(),
        'profile_private':  _notesCtrl.text.trim(),
        'agent_name':       _agentNameCtrl.text.trim(),
        if (_voicePref != null) 'voice_preference': _voicePref,
        if (_matchingPaused != null) 'matching_paused': _matchingPaused,
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

  Future<void> _pickAndUploadPhoto() async {
    if (_uploadingPhoto) return;
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1800,
    );
    if (picked == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await BackendService.uploadMedia(bytes, picked.name);
      await FirestoreService.saveMediaRecord(photoUrl: url);
      ref.invalidate(insightsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo uploaded. Ayma is processing it now.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Photo upload failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  @override
  void dispose() {
    _bioCtrl.dispose();
    _notesCtrl.dispose();
    _agentNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: profileAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(strokeWidth: 1.5, color: AymaColors.accent),
          ),
          error: (e, _) => Center(
            child: Text('Error loading profile', style: TextStyle(color: AymaColors.fgDim)),
          ),
          data: (profile) {
            if (profile == null) {
              return Center(
                child: Text('No profile found', style: TextStyle(color: AymaColors.fgDim)),
              );
            }
            return _editing
                ? _EditView(
                    profile:        profile,
                    bioCtrl:        _bioCtrl,
                    notesCtrl:      _notesCtrl,
                    agentNameCtrl:  _agentNameCtrl,
                    voicePref:      _voicePref ?? profile.voicePreference,
                    matchingPaused: _matchingPaused ?? profile.matchingPaused,
                    saving:         _saving,
                    onVoiceChange:  (v) => setState(() => _voicePref = v),
                    onPauseChange:  (v) => setState(() => _matchingPaused = v),
                    onSave:         () => _save(profile),
                    onCancel:       () => setState(() => _editing = false),
                  )
                : _ReadView(profile: profile, onEdit: () => _startEdit(profile));
          },
        ),
      ),
      floatingActionButton: _editing
          ? null
          : FloatingActionButton.extended(
              onPressed: _uploadingPhoto ? null : _pickAndUploadPhoto,
              backgroundColor: AymaColors.accent,
              foregroundColor: Colors.black,
              icon: _uploadingPhoto
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined),
              label: Text(_uploadingPhoto ? 'Uploading...' : 'Add Photo'),
            ),
    );
  }
}

// ── Read view ─────────────────────────────────────────────────────────────────

class _ReadView extends ConsumerWidget {
  final UserProfile profile;
  final VoidCallback onEdit;
  const _ReadView({required this.profile, required this.onEdit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insightsAsync = ref.watch(insightsProvider);
    final insights = insightsAsync.valueOrNull ?? const <String, String>{};
    String? preview;
    for (final key in const ['about_me', 'preferences', 'context']) {
      final text = (insights[key] ?? '').trim();
      if (text.isNotEmpty) {
        preview = text.split('\n').first.trim();
        break;
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        // Header
        Row(
          children: [
            Text(
              'You',
              style: AymaFonts.serif(size: 36, color: AymaColors.fg),
            ).animate().fadeIn(duration: 400.ms),
            const Spacer(),
            Row(
              children: [
                GestureDetector(
                  onTap: () => context.push('/settings'),
                  child: Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AymaColors.bgElev,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                    ),
                    child: Icon(Icons.settings_outlined, size: 16, color: AymaColors.fgDim),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onEdit,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AymaColors.bgElev,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined, size: 14, color: AymaColors.fgDim),
                        const SizedBox(width: 5),
                        Text('Edit', style: TextStyle(color: AymaColors.fgDim, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Avatar + name
        Center(
          child: Column(
            children: [
              Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AymaColors.accent.withValues(alpha: 0.12),
                  border: Border.all(
                    color: AymaColors.accent.withValues(alpha: 0.3), width: 1.5),
                ),
                child: Center(
                  child: Text(
                    profile.displayName.isNotEmpty
                        ? profile.displayName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                        color: AymaColors.accent, fontSize: 32, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                profile.displayName.isNotEmpty ? profile.displayName : 'You',
                style: AymaFonts.serif(size: 26, color: AymaColors.fg),
              ),
              const SizedBox(height: 4),
              if (profile.age != null || profile.locationRegion != null)
                Text(
                  [
                    if (profile.age != null) '${profile.age}',
                    if (profile.gender != null) profile.gender!,
                    if (profile.locationRegion != null) profile.locationRegion!,
                  ].join(' · '),
                  style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
                ),
              const SizedBox(height: 4),
              // Agent + voice row
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MiniPill(label: profile.agentName),
                  const SizedBox(width: 6),
                  _MiniPill(label: profile.voicePreference),
                  if (profile.matchingPaused) ...[
                    const SizedBox(width: 6),
                    _MiniPill(label: 'Paused', accent: true),
                  ],
                ],
              ),
            ],
          ),
        ).animate(delay: 80.ms).fadeIn(duration: 400.ms),

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
                  ? AymaColors.fg
                  : AymaColors.fgMute,
              fontSize: 14, height: 1.6,
            ),
          ),
        ).animate(delay: 160.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

        const SizedBox(height: 14),

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
                  ? AymaColors.fg
                  : AymaColors.fgMute,
              fontSize: 14, height: 1.6,
            ),
          ),
        ).animate(delay: 220.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

        if (profile.matchingPrefs.isNotEmpty) ...[
          const SizedBox(height: 14),
          _Section(
            title: 'Matching preferences',
            child: _PrefsView(prefs: profile.matchingPrefs),
          ).animate(delay: 280.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),
        ],

        const SizedBox(height: 14),
        _YourStoryCard(preview: preview)
            .animate(delay: 340.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),
      ],
    );
  }
}

// ── Edit view ─────────────────────────────────────────────────────────────────

const _kVoiceOptions = ['Charon', 'Linden', 'March', 'Harbor', 'Ash'];

class _EditView extends StatelessWidget {
  final UserProfile profile;
  final TextEditingController bioCtrl, notesCtrl, agentNameCtrl;
  final String voicePref;
  final bool matchingPaused;
  final bool saving;
  final void Function(String) onVoiceChange;
  final void Function(bool) onPauseChange;
  final VoidCallback onSave, onCancel;

  const _EditView({
    required this.profile,
    required this.bioCtrl,
    required this.notesCtrl,
    required this.agentNameCtrl,
    required this.voicePref,
    required this.matchingPaused,
    required this.saving,
    required this.onVoiceChange,
    required this.onPauseChange,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        // Header
        Row(
          children: [
            GestureDetector(
              onTap: onCancel,
              child: Icon(Icons.arrow_back_rounded, color: AymaColors.fgDim),
            ),
            const SizedBox(width: 14),
            Text('Edit profile', style: AymaFonts.serif(size: 22, color: AymaColors.fg)),
          ],
        ),
        const SizedBox(height: 28),

        _FieldLabel('Agent name'),
        const SizedBox(height: 8),
        AymaTextField(controller: agentNameCtrl, label: 'e.g. Ayma', maxLines: 1),

        const SizedBox(height: 20),

        _FieldLabel('Voice'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8, runSpacing: 8,
          children: _kVoiceOptions.map((v) => GestureDetector(
            onTap: () => onVoiceChange(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: voicePref == v
                    ? AymaColors.accent.withValues(alpha: 0.15)
                    : AymaColors.bgElev,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: voicePref == v
                      ? AymaColors.accent.withValues(alpha: 0.5)
                      : AymaColors.lineSoft,
                  width: voicePref == v ? 1 : 0.5,
                ),
              ),
              child: Text(
                v,
                style: TextStyle(
                  color: voicePref == v ? AymaColors.accent : AymaColors.fgDim,
                  fontSize: 13,
                  fontWeight: voicePref == v ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          )).toList(),
        ),

        const SizedBox(height: 20),

        _FieldLabel('Public bio'),
        const SizedBox(height: 8),
        AymaTextField(controller: bioCtrl, label: 'Bio', maxLines: 5),

        const SizedBox(height: 20),

        _FieldLabel('Private notes'),
        const SizedBox(height: 4),
        Text(
          'Only visible to you — Ayma uses this to understand you better.',
          style: TextStyle(color: AymaColors.fgMute, fontSize: 11),
        ),
        const SizedBox(height: 8),
        AymaTextField(controller: notesCtrl, label: 'Notes (only you see this)', maxLines: 5),

        const SizedBox(height: 20),

        // Matching paused toggle
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AymaColors.bgElev,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pause matching',
                        style: TextStyle(color: AymaColors.fg, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text('Hide your profile from new matches',
                        style: TextStyle(color: AymaColors.fgMute, fontSize: 12)),
                  ],
                ),
              ),
              Switch(
                value: matchingPaused,
                onChanged: onPauseChange,
                activeColor: AymaColors.accent,
                inactiveThumbColor: AymaColors.fgMute,
                inactiveTrackColor: AymaColors.lineSoft,
              ),
            ],
          ),
        ),

        const SizedBox(height: 28),
        AymaButton(label: 'Save changes', loading: saving, onPressed: onSave),
        const SizedBox(height: 12),
        AymaButton(label: 'Cancel', outlined: true, onPressed: onCancel),
      ],
    );
  }
}

// ── Prefs view (all keys) ─────────────────────────────────────────────────────

class _PrefsView extends StatelessWidget {
  final Map<String, dynamic> prefs;
  const _PrefsView({required this.prefs});

  String _label(String key, dynamic value) {
    final label = key.replaceAll('_', ' ');
    if (value is bool) return '$label: ${value ? 'yes' : 'no'}';
    if (value is List) return '$label: ${value.join(', ')}';
    return '$label: $value';
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: prefs.entries
          .where((e) => e.value != null && e.value.toString().isNotEmpty)
          .map((e) => _Chip(_label(e.key, e.value)))
          .toList(),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
  );
}

class _MiniPill extends StatelessWidget {
  final String label;
  final bool accent;
  const _MiniPill({required this.label, this.accent = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: accent
          ? AymaColors.accent.withValues(alpha: 0.12)
          : AymaColors.bgElev,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: accent
            ? AymaColors.accent.withValues(alpha: 0.3)
            : AymaColors.lineSoft,
        width: 0.5,
      ),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: accent ? AymaColors.accent : AymaColors.fgMute,
        fontSize: 10,
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? badge;
  final Color? badgeColor;
  final Widget child;

  const _Section({
    required this.title,
    this.subtitle,
    this.badge,
    this.badgeColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
              ),
              if (badge != null) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (badgeColor ?? AymaColors.accent).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      color: badgeColor ?? AymaColors.accent,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(subtitle!, style: TextStyle(color: AymaColors.fgMute, fontSize: 11)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
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
      color: AymaColors.bgCard,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AymaColors.lineSoft, width: 0.5),
    ),
    child: Text(label, style: TextStyle(color: AymaColors.fgDim, fontSize: 12)),
  );
}

// ── Your Story card ────────────────────────────────────────────────────────────

class _YourStoryCard extends StatelessWidget {
  final String? preview;
  const _YourStoryCard({this.preview});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go('/insights'),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AymaColors.accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: AymaColors.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AymaColors.accent.withValues(alpha: 0.3), width: 0.5),
              ),
              child: const Icon(Icons.auto_stories_rounded,
                  size: 18, color: AymaColors.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'YOUR STORY',
                    style: AymaFonts.mono(size: 9, color: AymaColors.accent),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    preview ?? 'What Ayma has learned about you',
                    style: TextStyle(
                      color: preview != null ? AymaColors.fgDim : AymaColors.fgMute,
                      fontSize: 12, height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_ios_rounded,
                size: 12, color: AymaColors.accent.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}
