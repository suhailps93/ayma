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
      ref.invalidate(publicProfileProvider(profile.id));
      ref.invalidate(insightsProvider);
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pickAndUploadPhoto(UserProfile profile) async {
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
      ref.invalidate(publicProfileProvider(profile.id));
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
              onPressed: _uploadingPhoto || profileAsync.valueOrNull == null
                  ? null
                  : () => _pickAndUploadPhoto(profileAsync.valueOrNull!),
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
    final publicProfileAsync = ref.watch(publicProfileProvider(profile.id));
    final insightsAsync = ref.watch(insightsProvider);
    final publicProfile = publicProfileAsync.valueOrNull ?? const <String, dynamic>{};
    final insights = insightsAsync.valueOrNull ?? const <String, String>{};

    final photos = ((publicProfile['photos'] as List?) ?? const [])
        .whereType<String>()
        .map((photo) => photo.trim())
        .where((photo) => photo.isNotEmpty)
        .toList();

    final name = _stringOrFallback([
      publicProfile['display_name'],
      profile.displayName,
      'You',
    ]);
    final age = _ageOrNull([
      publicProfile['age'],
      profile.age,
    ]);
    final gender = _stringOrFallback([
      publicProfile['gender'],
      profile.gender,
    ]);
    final location = _stringOrFallback([
      publicProfile['location_region'],
      profile.locationRegion,
    ]);
    final interestedIn = _stringOrFallback([
      (publicProfile['matching_prefs'] as Map?)?['interested_in'],
      profile.matchingPrefs['interested_in'],
    ]);
    final bio = _stringOrFallback([
      publicProfile['profile_public'],
      profile.profilePublic,
      'No public bio yet. Talk to Ayma to build your profile.',
    ]);
    final aboutMe = _storyText(insights, 'about_me');
    final preferences = _storyText(insights, 'preferences');
    final contextText = _storyText(insights, 'context');
    final mediaText = _storyText(insights, 'media');

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
        const SizedBox(height: 22),

        _PublicHeroSection(
          name: name,
          age: age,
          gender: gender,
          location: location,
          interestedIn: interestedIn,
          agentName: profile.agentName,
          voicePreference: profile.voicePreference,
          matchingPaused: profile.matchingPaused,
          photos: photos,
          loadingPhotos: publicProfileAsync.isLoading && photos.isEmpty,
        ).animate(delay: 80.ms).fadeIn(duration: 400.ms),

        const SizedBox(height: 14),

        Row(
          children: [
            Expanded(
              child: _InlineAction(
                label: 'Edit profile',
                icon: Icons.edit_outlined,
                onTap: onEdit,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _InlineAction(
                label: 'Settings',
                icon: Icons.settings_outlined,
                onTap: () => context.push('/settings'),
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        _Section(
          title: 'Public profile',
          badge: !profile.profilePublicLocked ? 'AI written' : 'Edited',
          badgeColor: !profile.profilePublicLocked
              ? AymaColors.accent
              : Colors.green.shade400,
          child: Text(
            bio,
            style: TextStyle(color: AymaColors.fg, fontSize: 14, height: 1.6),
          ),
        ).animate(delay: 160.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

        const SizedBox(height: 14),

        _Section(
          title: 'Your story',
          subtitle: 'Updated after every conversation with Ayma.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StorySnippet(
                label: 'About you',
                text: aboutMe,
              ),
              const SizedBox(height: 10),
              _StorySnippet(
                label: "What you're looking for",
                text: preferences,
              ),
              const SizedBox(height: 10),
              _StorySnippet(
                label: 'Right now',
                text: contextText,
              ),
              if (mediaText.isNotEmpty) ...[
                const SizedBox(height: 10),
                _StorySnippet(
                  label: 'Photos',
                  text: mediaText,
                ),
              ],
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => context.go('/insights'),
                child: Row(
                  children: [
                    Text(
                      'Open full story',
                      style: TextStyle(
                        color: AymaColors.accent,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 12,
                      color: AymaColors.accent.withValues(alpha: 0.7),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ).animate(delay: 220.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

        const SizedBox(height: 14),

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
        ).animate(delay: 280.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

        if (profile.matchingPrefs.isNotEmpty) ...[
          const SizedBox(height: 14),
          _Section(
            title: 'Matching preferences',
            child: _PrefsView(prefs: profile.matchingPrefs),
          ).animate(delay: 340.ms).fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),
        ],
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

class _PublicHeroSection extends StatelessWidget {
  final String name;
  final int? age;
  final String? gender;
  final String? location;
  final String? interestedIn;
  final String agentName;
  final String voicePreference;
  final bool matchingPaused;
  final List<String> photos;
  final bool loadingPhotos;

  const _PublicHeroSection({
    required this.name,
    required this.age,
    required this.gender,
    required this.location,
    required this.interestedIn,
    required this.agentName,
    required this.voicePreference,
    required this.matchingPaused,
    required this.photos,
    required this.loadingPhotos,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhotos = photos.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 224,
          decoration: BoxDecoration(
            color: AymaColors.bgElev,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
          ),
          clipBehavior: Clip.hardEdge,
          child: hasPhotos
              ? ListView.separated(
                  padding: const EdgeInsets.all(12),
                  scrollDirection: Axis.horizontal,
                  itemCount: photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: AspectRatio(
                      aspectRatio: 0.82,
                      child: Image.network(
                        photos[index],
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _PhotoFallback(name: name),
                      ),
                    ),
                  ),
                )
              : _PhotoFallback(
                  name: name,
                  loading: loadingPhotos,
                ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AymaColors.bgElev,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: AymaFonts.serif(size: 30, color: AymaColors.fg),
              ),
              const SizedBox(height: 8),
              Text(
                [
                  if (age != null) '$age',
                  if (gender != null && gender!.isNotEmpty) gender!,
                  if (interestedIn != null && interestedIn!.isNotEmpty)
                    'Interested in $interestedIn',
                  if (location != null && location!.isNotEmpty) location!,
                ].join(' · '),
                style: const TextStyle(color: AymaColors.fgMute, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MiniPill(label: agentName),
                  _MiniPill(label: voicePreference),
                  if (matchingPaused) _MiniPill(label: 'Paused', accent: true),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoFallback extends StatelessWidget {
  final String name;
  final bool loading;

  const _PhotoFallback({
    required this.name,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AymaColors.accent.withValues(alpha: 0.18),
            AymaColors.bgCard,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AymaColors.accent,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AymaColors.accent.withValues(alpha: 0.14),
                      border: Border.all(
                        color: AymaColors.accent.withValues(alpha: 0.25),
                        width: 1.2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: TextStyle(
                        color: AymaColors.accent,
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'No photos yet',
                    style: AymaFonts.serif(size: 20, color: AymaColors.fg),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Add photos to build your public profile.',
                    style: TextStyle(
                      color: AymaColors.fgMute,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _InlineAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _InlineAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: AymaColors.fgDim),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AymaColors.fgDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StorySnippet extends StatelessWidget {
  final String label;
  final String text;

  const _StorySnippet({
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final hasText = text.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AymaColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
          ),
          const SizedBox(height: 6),
          Text(
            hasText ? text : 'Ayma is still learning this from your conversations.',
            style: TextStyle(
              color: hasText ? AymaColors.fg : AymaColors.fgMute,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

String _stringOrFallback(Iterable<dynamic> values) {
  for (final value in values) {
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

int? _ageOrNull(Iterable<dynamic> values) {
  for (final value in values) {
    if (value is int) return value;
    if (value is num) return value.toInt();
  }
  return null;
}

String _storyText(Map<String, String> insights, String key) {
  final raw = (insights[key] ?? '').trim();
  if (raw.isEmpty) return '';
  final firstLine = raw.split('\n').first.trim();
  return firstLine.isEmpty ? raw : firstLine;
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
