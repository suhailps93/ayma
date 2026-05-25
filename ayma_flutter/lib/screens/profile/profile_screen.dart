import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/profile.dart';
import '../../providers/providers.dart';
import '../../services/backend_service.dart';
import '../../services/firestore_service.dart';
import '../../theme.dart';
import '../../widgets/ayma_button.dart';
import '../../widgets/ayma_text_field.dart';

// ─── Top-level helpers ────────────────────────────────────────────────────────

String _first(Iterable<dynamic> values) {
  for (final v in values) {
    if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
  }
  return '';
}

int? _age(Iterable<dynamic> values) {
  for (final v in values) {
    if (v == null) continue;
    if (v is int && v > 0) return v;
    final n = int.tryParse(v.toString());
    if (n != null && n > 0) return n;
  }
  return null;
}

String _cityOnly(String region) {
  if (region.isEmpty) return '';
  return region.split(',').first.trim();
}

String _relativeDate(String isoDate) {
  if (isoDate.isEmpty) return '';
  try {
    final dt = DateTime.parse(isoDate);
    final diff = DateTime.now().difference(dt);
    if (diff.inDays == 0) return 'Updated today';
    if (diff.inDays == 1) return 'Updated yesterday';
    if (diff.inDays < 7) return 'Updated ${diff.inDays}d ago';
    return 'Updated $isoDate';
  } catch (_) {
    return 'Updated $isoDate';
  }
}

// ─── ProfileScreen ────────────────────────────────────────────────────────────

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  bool _editingBasic = false;
  bool _saving = false;
  bool _uploadingPhoto = false;

  final _bioCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _agentNameCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();

  String? _voicePref;
  bool? _matchingPaused;
  String? _genderVal;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _bioCtrl.dispose();
    _notesCtrl.dispose();
    _agentNameCtrl.dispose();
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  void _startEdit(UserProfile profile) {
    _bioCtrl.text = profile.profilePublic ?? '';
    _notesCtrl.text = profile.profilePrivate ?? '';
    _agentNameCtrl.text = profile.agentName;
    _nameCtrl.text = profile.displayName;
    _ageCtrl.text = profile.age?.toString() ?? '';
    _locationCtrl.text = profile.locationRegion ?? '';
    _genderVal = profile.gender;
    _voicePref = profile.voicePreference;
    _matchingPaused = profile.matchingPaused;
    setState(() => _editingBasic = true);
  }

  Future<void> _save(UserProfile profile) async {
    setState(() => _saving = true);
    try {
      final ageInt = int.tryParse(_ageCtrl.text.trim());
      await FirestoreService.updateProfile({
        if (_nameCtrl.text.trim().isNotEmpty)
          'display_name': _nameCtrl.text.trim(),
        'profile_public': _bioCtrl.text.trim(),
        'profile_private': _notesCtrl.text.trim(),
        'agent_name': _agentNameCtrl.text.trim(),
        if (ageInt != null) 'age': ageInt,
        if (_locationCtrl.text.trim().isNotEmpty)
          'location_region': _locationCtrl.text.trim(),
        if (_genderVal != null) 'gender': _genderVal,
        if (_voicePref != null) 'voice_preference': _voicePref,
        if (_matchingPaused != null) 'matching_paused': _matchingPaused,
      });
      ref.invalidate(profileProvider);
      ref.invalidate(publicProfileProvider(profile.id));
      ref.invalidate(insightsProvider);
      if (mounted) setState(() => _editingBasic = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _addPhoto(UserProfile profile) async {
    final picker = ImagePicker();
    final picked =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await BackendService.uploadMedia(bytes, picked.name);
      await FirestoreService.saveMediaRecord(photoUrl: url);
      ref.invalidate(publicProfileProvider(profile.id));
      ref.invalidate(insightsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Photo uploaded. Ayma is processing it now.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
      }
    }
    if (mounted) setState(() => _uploadingPhoto = false);
  }

  Future<void> _toggleLocked(UserProfile profile) async {
    try {
      await FirestoreService.updateProfile(
          {'profile_public_locked': !profile.profilePublicLocked});
      ref.invalidate(profileProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: profileAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: AymaColors.accent),
        ),
        error: (e, _) => Center(
          child: Text('Error: $e',
              style: const TextStyle(color: AymaColors.fgDim)),
        ),
        data: (profile) {
          if (profile == null) {
            return const Center(
              child: Text('No profile found.',
                  style: TextStyle(color: AymaColors.fgMute)),
            );
          }

          if (_editingBasic) {
            return _EditFormView(
              profile: profile,
              bioCtrl: _bioCtrl,
              notesCtrl: _notesCtrl,
              agentNameCtrl: _agentNameCtrl,
              nameCtrl: _nameCtrl,
              ageCtrl: _ageCtrl,
              locationCtrl: _locationCtrl,
              voicePref: _voicePref,
              matchingPaused: _matchingPaused,
              genderVal: _genderVal,
              saving: _saving,
              onSave: () => _save(profile),
              onBack: () => setState(() => _editingBasic = false),
              onVoiceChanged: (v) => setState(() => _voicePref = v),
              onMatchingPausedChanged: (v) =>
                  setState(() => _matchingPaused = v),
              onGenderChanged: (v) => setState(() => _genderVal = v),
            );
          }

          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: _PillTabBar(controller: _tabController),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _YourStoryPane(profile: profile),
                      _EditPublicPane(
                        profile: profile,
                        uploadingPhoto: _uploadingPhoto,
                        onStartEdit: () => _startEdit(profile),
                        onAddPhoto: () => _addPhoto(profile),
                        onToggleLocked: () => _toggleLocked(profile),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─── Pill Tab Bar ─────────────────────────────────────────────────────────────

class _PillTabBar extends StatelessWidget {
  const _PillTabBar({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: TabBar(
        controller: controller,
        indicator: BoxDecoration(
          color: AymaColors.fg,
          borderRadius: BorderRadius.circular(20),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: const EdgeInsets.all(4),
        dividerColor: Colors.transparent,
        labelColor: AymaColors.bg,
        unselectedLabelColor: AymaColors.fgMute,
        labelStyle: AymaFonts.sans(size: 13, weight: FontWeight.w600),
        unselectedLabelStyle: AymaFonts.sans(size: 13),
        tabs: const [
          Tab(text: 'Private Profile'),
          Tab(text: 'Public Profile'),
        ],
      ),
    );
  }
}

// ─── Tab 0: Private Profile (wiki) ───────────────────────────────────────────

class _YourStoryPane extends ConsumerWidget {
  const _YourStoryPane({required this.profile});
  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insightsAsync = ref.watch(insightsProvider);

    return insightsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: AymaColors.accent),
      ),
      error: (e, _) => Center(
        child: Text('Error: $e',
            style: const TextStyle(color: AymaColors.fgMute)),
      ),
      data: (insights) {
        final i = insights as Map<String, dynamic>? ?? const <String, dynamic>{};
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          children: [
            _AymaBanner().animate().fadeIn(duration: 300.ms),
            const SizedBox(height: 16),

            _StoryCard(
              label: 'WHO YOU ARE',
              content: i['about_me']?.toString() ?? '',
              updatedAt: i['about_me_updated_at']?.toString() ?? '',
            ).animate(delay: 40.ms).fadeIn(duration: 300.ms).slideY(begin: 0.03, end: 0),
            const SizedBox(height: 10),

            _StoryCard(
              label: "WHAT YOU'RE LOOKING FOR",
              content: i['preferences']?.toString() ?? '',
              updatedAt: i['preferences_updated_at']?.toString() ?? '',
            ).animate(delay: 80.ms).fadeIn(duration: 300.ms).slideY(begin: 0.03, end: 0),
            const SizedBox(height: 10),

            _StoryCard(
              label: 'YOUR LIFE RIGHT NOW',
              content: i['context']?.toString() ?? '',
              updatedAt: i['context_updated_at']?.toString() ?? '',
            ).animate(delay: 120.ms).fadeIn(duration: 300.ms).slideY(begin: 0.03, end: 0),
            const SizedBox(height: 10),

            _StoryCard(
              label: 'FOR MATCHING',
              content: i['matching']?.toString() ?? '',
              updatedAt: i['matching_updated_at']?.toString() ?? '',
            ).animate(delay: 160.ms).fadeIn(duration: 300.ms).slideY(begin: 0.03, end: 0),
          ],
        );
      },
    );
  }
}

// ─── Ayma banner ──────────────────────────────────────────────────────────────

class _AymaBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: AymaColors.accent.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4, right: 10),
            decoration: const BoxDecoration(
              color: AymaColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This is what I know about you so far. It updates every time we talk.',
                  style: AymaFonts.sans(
                      size: 13,
                      color: AymaColors.fgDim),
                ),
                const SizedBox(height: 6),
                Text(
                  'ONLY YOU CAN SEE THIS',
                  style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Story card (expandable) ──────────────────────────────────────────────────

class _StoryCard extends StatefulWidget {
  const _StoryCard({
    required this.label,
    required this.content,
    required this.updatedAt,
  });
  final String label;
  final String content;
  final String updatedAt;

  @override
  State<_StoryCard> createState() => _StoryCardState();
}

class _StoryCardState extends State<_StoryCard> {
  bool _expanded = false;

  static const int _previewChars = 120;

  @override
  Widget build(BuildContext context) {
    final hasContent = widget.content.trim().isNotEmpty;
    final relDate = _relativeDate(widget.updatedAt);
    final trimmed = widget.content.trim();
    final needsTruncation = trimmed.length > _previewChars;
    final preview = needsTruncation
        ? '${trimmed.substring(0, _previewChars).trimRight()}…'
        : trimmed;

    return GestureDetector(
      onTap: hasContent && needsTruncation
          ? () => setState(() => _expanded = !_expanded)
          : null,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.label,
                    style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
                if (relDate.isNotEmpty)
                  Text(relDate,
                      style: AymaFonts.mono(
                          size: 9,
                          color: AymaColors.fgMute.withValues(alpha: 0.6))),
              ],
            ),
            const SizedBox(height: 12),
            hasContent
                ? Text(_expanded ? trimmed : preview,
                    style: AymaFonts.serif(size: 16, color: AymaColors.fg))
                : Text('Nothing here yet — keep chatting with Ayma!',
                    style: AymaFonts.serif(
                        size: 15, color: AymaColors.fgMute, italic: true)),
            if (hasContent) ...[
              if (needsTruncation) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      _expanded ? 'Show less' : 'Show more',
                      style: TextStyle(
                          color: AymaColors.accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: AymaColors.accent,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Divider(
                  color: AymaColors.lineSoft.withValues(alpha: 0.6),
                  thickness: 0.5,
                  height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 13, color: AymaColors.fgMute),
                  const SizedBox(width: 6),
                  Text("Disagree? Tell me in our next talk.",
                      style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Tab 1: Edit (public profile) ────────────────────────────────────────────

class _EditPublicPane extends ConsumerWidget {
  const _EditPublicPane({
    required this.profile,
    required this.uploadingPhoto,
    required this.onStartEdit,
    required this.onAddPhoto,
    required this.onToggleLocked,
  });

  final UserProfile profile;
  final bool uploadingPhoto;
  final VoidCallback onStartEdit;
  final VoidCallback onAddPhoto;
  final VoidCallback onToggleLocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final publicAsync = ref.watch(publicProfileProvider(profile.id));

    return publicAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: AymaColors.accent),
      ),
      error: (e, _) => Center(
        child: Text('Error: $e',
            style: const TextStyle(color: AymaColors.fgMute)),
      ),
      data: (pub) {
        final p = pub ?? const <String, dynamic>{};
        final photos = ((p['photos'] as List?) ?? const [])
            .whereType<String>()
            .where((u) => u.isNotEmpty)
            .toList();

        // Use profile fields directly — they come from onboarding / edit saves
        final name = profile.displayName.isNotEmpty
            ? profile.displayName
            : _first([p['display_name']]);
        final age = profile.age ?? _age([p['age']]);
        final gender = _first([profile.gender, p['gender']]);
        final location = _cityOnly(
            _first([profile.locationRegion, p['location_region']]));
        final interestedIn = _first([
          profile.matchingPrefs['interested_in'],
          (p['matching_prefs'] as Map?)?['interested_in'],
        ]);
        final bio = _first([profile.profilePublic, p['profile_public']]);

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          children: [
            // Photos
            _PhotoCarousel(
              photos: photos,
              uploadingPhoto: uploadingPhoto,
              onAddPhoto: onAddPhoto,
            ).animate().fadeIn(duration: 300.ms),
            const SizedBox(height: 24),

            // Basics
            Text('BASICS',
                style: AymaFonts.mono(size: 9, color: AymaColors.fgMute))
                .animate(delay: 80.ms).fadeIn(duration: 300.ms),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: AymaColors.bgElev,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AymaColors.lineSoft, width: 0.5),
              ),
              child: Column(
                children: [
                  _BasicRow(
                      label: 'Name',
                      value: name.isNotEmpty ? name : '—',
                      onTap: onStartEdit),
                  _RowDivider(),
                  _BasicRow(
                      label: 'Age',
                      value: age != null ? '$age' : '—',
                      onTap: onStartEdit),
                  _RowDivider(),
                  _BasicRow(
                      label: 'Gender',
                      value: gender.isNotEmpty ? gender : '—',
                      onTap: onStartEdit),
                  _RowDivider(),
                  _BasicRow(
                      label: 'Location',
                      value: location.isNotEmpty ? location : '—',
                      onTap: onStartEdit),
                  _RowDivider(),
                  _BasicRow(
                      label: 'Interested in',
                      value: interestedIn.isNotEmpty ? interestedIn : '—',
                      onTap: onStartEdit),
                ],
              ),
            ).animate(delay: 100.ms).fadeIn(duration: 300.ms),
            const SizedBox(height: 24),

            // Public bio
            Text('PUBLIC BIO',
                style: AymaFonts.mono(size: 9, color: AymaColors.fgMute))
                .animate(delay: 140.ms).fadeIn(duration: 300.ms),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AymaColors.bgElev,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AymaColors.lineSoft, width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('What others see',
                          style: AymaFonts.sans(
                              size: 12, color: AymaColors.fgMute)),
                      GestureDetector(
                        onTap: onStartEdit,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AymaColors.bgCard,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AymaColors.lineSoft, width: 0.5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.edit_outlined,
                                  size: 11, color: AymaColors.fgMute),
                              const SizedBox(width: 4),
                              Text('Edit',
                                  style: AymaFonts.sans(
                                      size: 11, color: AymaColors.fgMute)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  bio.isNotEmpty
                      ? Text(bio,
                          style: const TextStyle(
                              color: AymaColors.fg,
                              fontSize: 14,
                              height: 1.65))
                      : Text(
                          'No public bio yet. Talk to Ayma to build your profile.',
                          style: TextStyle(
                              color: AymaColors.fgMute,
                              fontSize: 13,
                              height: 1.6,
                              fontStyle: FontStyle.italic)),
                  const SizedBox(height: 14),
                  Divider(
                      color: AymaColors.lineSoft.withValues(alpha: 0.6),
                      thickness: 0.5,
                      height: 1),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: onToggleLocked,
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: profile.profilePublicLocked
                                ? Colors.green.shade900
                                    .withValues(alpha: 0.4)
                                : AymaColors.accent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: profile.profilePublicLocked
                                  ? Colors.green.shade600
                                      .withValues(alpha: 0.4)
                                  : AymaColors.accent.withValues(alpha: 0.3),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                profile.profilePublicLocked
                                    ? Icons.lock_outline_rounded
                                    : Icons.auto_awesome_outlined,
                                size: 11,
                                color: profile.profilePublicLocked
                                    ? Colors.green.shade400
                                    : AymaColors.accent,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                profile.profilePublicLocked
                                    ? 'User edited'
                                    : 'AI written',
                                style: TextStyle(
                                  color: profile.profilePublicLocked
                                      ? Colors.green.shade400
                                      : AymaColors.accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          profile.profilePublicLocked
                              ? 'Tap to let Ayma update'
                              : 'Tap to lock',
                          style: const TextStyle(
                              color: AymaColors.fgMute, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ).animate(delay: 160.ms).fadeIn(duration: 300.ms),
          ],
        );
      },
    );
  }
}

// ─── Photo carousel ───────────────────────────────────────────────────────────

class _PhotoCarousel extends StatefulWidget {
  const _PhotoCarousel({
    required this.photos,
    required this.uploadingPhoto,
    required this.onAddPhoto,
  });
  final List<String> photos;
  final bool uploadingPhoto;
  final VoidCallback onAddPhoto;

  @override
  State<_PhotoCarousel> createState() => _PhotoCarouselState();
}

class _PhotoCarouselState extends State<_PhotoCarousel> {
  int _page = 0;
  late final PageController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = PageController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final hasPhotos = photos.isNotEmpty;
    final h = MediaQuery.sizeOf(context).width * 1.1; // slightly taller than square

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section label + count
        Row(
          children: [
            Text('PHOTOS',
                style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
            if (hasPhotos) ...[
              const SizedBox(width: 8),
              Text('· ${photos.length}',
                  style: AymaFonts.mono(
                      size: 9,
                      color: AymaColors.fgMute.withValues(alpha: 0.5))),
            ],
          ],
        ),
        const SizedBox(height: 10),

        // Carousel or empty state
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: h,
            child: hasPhotos
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      PageView.builder(
                        controller: _ctrl,
                        itemCount: photos.length,
                        onPageChanged: (i) => setState(() => _page = i),
                        itemBuilder: (_, i) => Image.network(
                          photos[i],
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Container(color: AymaColors.bgCard),
                        ),
                      ),
                      // STRONGEST badge on first photo
                      if (_page == 0)
                        Positioned(
                          top: 12,
                          left: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AymaColors.accent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('STRONGEST',
                                style: AymaFonts.mono(
                                    size: 8, color: Colors.black)),
                          ),
                        ),
                      // Page dots
                      if (photos.length > 1)
                        Positioned(
                          bottom: 12,
                          left: 0,
                          right: 0,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(photos.length, (i) {
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                width: _page == i ? 18 : 5,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: _page == i
                                      ? AymaColors.fg
                                      : AymaColors.fg.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              );
                            }),
                          ),
                        ),
                    ],
                  )
                : Container(
                    color: AymaColors.bgElev,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AymaColors.accent.withValues(alpha: 0.08),
                            border: Border.all(
                                color: AymaColors.accent.withValues(alpha: 0.2),
                                width: 1),
                          ),
                          child: const Icon(Icons.photo_library_outlined,
                              color: AymaColors.accent, size: 24),
                        ),
                        const SizedBox(height: 14),
                        Text('No photos yet',
                            style: AymaFonts.serif(
                                size: 18, color: AymaColors.fg)),
                        const SizedBox(height: 6),
                        Text('Add some to complete your profile',
                            style: AymaFonts.sans(
                                size: 12, color: AymaColors.fgMute)),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),

        // Add photo button
        GestureDetector(
          onTap: widget.uploadingPhoto ? null : widget.onAddPhoto,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AymaColors.bgElev,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AymaColors.lineSoft, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.uploadingPhoto)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: AymaColors.accent),
                  )
                else
                  const Icon(Icons.add_photo_alternate_outlined,
                      size: 16, color: AymaColors.accent),
                const SizedBox(width: 7),
                Text(
                  widget.uploadingPhoto ? 'Uploading…' : 'Add photo',
                  style: TextStyle(
                      color: AymaColors.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Edit Form View ───────────────────────────────────────────────────────────

class _EditFormView extends StatelessWidget {
  const _EditFormView({
    required this.profile,
    required this.bioCtrl,
    required this.notesCtrl,
    required this.agentNameCtrl,
    required this.nameCtrl,
    required this.ageCtrl,
    required this.locationCtrl,
    required this.voicePref,
    required this.matchingPaused,
    required this.genderVal,
    required this.saving,
    required this.onSave,
    required this.onBack,
    required this.onVoiceChanged,
    required this.onMatchingPausedChanged,
    required this.onGenderChanged,
  });

  final UserProfile profile;
  final TextEditingController bioCtrl;
  final TextEditingController notesCtrl;
  final TextEditingController agentNameCtrl;
  final TextEditingController nameCtrl;
  final TextEditingController ageCtrl;
  final TextEditingController locationCtrl;
  final String? voicePref;
  final bool? matchingPaused;
  final String? genderVal;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onBack;
  final ValueChanged<String> onVoiceChanged;
  final ValueChanged<bool> onMatchingPausedChanged;
  final ValueChanged<String?> onGenderChanged;

  static const _voiceOptions = ['Charon', 'Linden', 'March', 'Harbor', 'Ash'];
  static const _genderOptions = ['Man', 'Woman', 'Non-binary', 'Other'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AymaColors.bg,
      appBar: AppBar(
        backgroundColor: AymaColors.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AymaColors.fgDim),
          onPressed: onBack,
        ),
        title: Text('Edit profile',
            style: AymaFonts.serif(size: 20, color: AymaColors.fg)),
        actions: [
          if (saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: AymaColors.accent)),
            )
          else
            TextButton(
              onPressed: onSave,
              child: Text('Save',
                  style: AymaFonts.sans(
                      size: 15,
                      color: AymaColors.accent,
                      weight: FontWeight.w600)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        children: [
          _FieldLabel('Name'),
          AymaTextField(
              controller: nameCtrl, label: 'Display name', maxLines: 1),
          const SizedBox(height: 16),

          _FieldLabel('Age'),
          AymaTextField(
              controller: ageCtrl,
              label: 'Age',
              maxLines: 1,
              keyboardType: TextInputType.number),
          const SizedBox(height: 16),

          _FieldLabel('Gender'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _genderOptions.map((g) {
              final sel = genderVal == g;
              return _SelectChip(
                label: g,
                selected: sel,
                onTap: () => onGenderChanged(sel ? null : g),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          _FieldLabel('Location'),
          AymaTextField(
              controller: locationCtrl,
              label: 'City or region',
              maxLines: 1),
          const SizedBox(height: 16),

          _FieldLabel('Agent name'),
          AymaTextField(
              controller: agentNameCtrl,
              label: "Your AI agent's name",
              maxLines: 1),
          const SizedBox(height: 16),

          _FieldLabel('Voice'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _voiceOptions.map((v) {
              final sel = voicePref == v;
              return _SelectChip(
                label: v,
                selected: sel,
                onTap: () => onVoiceChanged(v),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          _FieldLabel('Public bio'),
          AymaTextField(
              controller: bioCtrl,
              label: 'Visible to potential matches',
              maxLines: 5),
          const SizedBox(height: 16),

          _FieldLabel('Private notes'),
          const SizedBox(height: 4),
          const Text(
            'Only visible to you — Ayma uses this to understand you better.',
            style: TextStyle(color: AymaColors.fgMute, fontSize: 11),
          ),
          const SizedBox(height: 6),
          AymaTextField(
              controller: notesCtrl,
              label: 'Notes (only you see this)',
              maxLines: 5),
          const SizedBox(height: 20),

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
                          style:
                              AymaFonts.sans(size: 14, color: AymaColors.fg)),
                      const SizedBox(height: 2),
                      Text('Hide your profile from new matches',
                          style: AymaFonts.sans(
                              size: 12, color: AymaColors.fgMute)),
                    ],
                  ),
                ),
                Switch(
                  value: matchingPaused ?? false,
                  onChanged: onMatchingPausedChanged,
                  activeColor: AymaColors.accent,
                  inactiveThumbColor: AymaColors.fgMute,
                  inactiveTrackColor: AymaColors.lineSoft,
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),
          AymaButton(
              label: 'Save changes', loading: saving, onPressed: onSave),
          const SizedBox(height: 12),
          AymaButton(label: 'Cancel', outlined: true, onPressed: onBack),
        ],
      ),
    );
  }
}

// ─── Helper widgets ───────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label.toUpperCase(),
            style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
      );
}

class _BasicRow extends StatelessWidget {
  const _BasicRow(
      {required this.label, required this.value, required this.onTap});
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: AymaFonts.sans(size: 14, color: AymaColors.fgMute)),
            ),
            Text(value,
                style: AymaFonts.sans(size: 14, color: AymaColors.fg)),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: AymaColors.fgMute),
          ],
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: AymaColors.lineSoft.withValues(alpha: 0.6)),
      );
}

class _SelectChip extends StatelessWidget {
  const _SelectChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AymaColors.accent.withValues(alpha: 0.15)
              : AymaColors.bgElev,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AymaColors.accent.withValues(alpha: 0.5)
                : AymaColors.lineSoft,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AymaColors.accent : AymaColors.fgDim,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
