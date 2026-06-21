import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/profile.dart';
import '../../providers/providers.dart';
import '../../services/backend_service.dart';
import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/ayma_button.dart';
import '../../widgets/ayma_text_field.dart';
import '../../widgets/public_profile_view.dart';

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
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
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
      await ApiService.updateProfile({
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

  Future<ImageSource?> _pickPhotoSource() async {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: context.ac.bgElev,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  Icon(Icons.camera_alt_outlined, color: context.ac.fg),
              title: Text('Take photo',
                  style: TextStyle(color: context.ac.fg)),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined,
                  color: context.ac.fg),
              title: Text('Choose from gallery',
                  style: TextStyle(color: context.ac.fg)),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addPhoto(UserProfile profile) async {
    final source = await _pickPhotoSource();
    if (source == null) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await BackendService.uploadMedia(bytes, picked.name);
      await ApiService.saveMediaRecord(photoUrl: url);
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
      await ApiService.updateProfile(
          {'profile_public_locked': !profile.profilePublicLocked});
      ref.invalidate(profileProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _deletePhoto(UserProfile profile, String photoUrl) async {
    try {
      await ApiService.deleteMediaByUrl(photoUrl);
      ref.invalidate(publicProfileProvider(profile.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _reorderPhotos(UserProfile profile, List<String> ordered) async {
    try {
      await ApiService.updatePhotoOrder(ordered);
      ref.invalidate(publicProfileProvider(profile.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Reorder failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: context.ac.bg,
      body: profileAsync.when(
        loading: () => Center(
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: context.ac.accent),
        ),
        error: (e, _) => Center(
          child: Text('Error: $e',
              style: TextStyle(color: context.ac.fgDim)),
        ),
        data: (profile) {
          if (profile == null) {
            return Center(
              child: Text('No profile found.',
                  style: TextStyle(color: context.ac.fgMute)),
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
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Expanded(child: _TopTabs(controller: _tabController)),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => context.push('/settings'),
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: context.ac.bgElev,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: context.ac.lineSoft, width: 0.5),
                          ),
                          child: Icon(Icons.settings_outlined,
                              size: 17, color: context.ac.fgDim),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _PublicTabWithCompleteness(
                        profile: profile,
                        uploadingPhoto: _uploadingPhoto,
                        onStartEdit: () => _startEdit(profile),
                        onAddPhoto: () => _addPhoto(profile),
                        onToggleLocked: () => _toggleLocked(profile),
                        onDeletePhoto: (url) => _deletePhoto(profile, url),
                        onReorderPhotos: (ordered) =>
                            _reorderPhotos(profile, ordered),
                      ),
                      _YourStoryPane(profile: profile),
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

class _TopTabs extends StatelessWidget {
  const _TopTabs({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF14110F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF282118), width: 0.5),
      ),
      child: TabBar(
        controller: controller,
        indicator: BoxDecoration(
          color: context.ac.fg,
          borderRadius: BorderRadius.circular(10),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: const EdgeInsets.all(4),
        dividerColor: Colors.transparent,
        labelColor: context.ac.bg,
        unselectedLabelColor: context.ac.fgMute,
        labelStyle: AymaFonts.sans(size: 13, weight: FontWeight.w600),
        unselectedLabelStyle: AymaFonts.sans(size: 13),
        tabs: const [
          Tab(text: 'Public'),
          Tab(text: 'Private'),
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
      loading: () => Center(
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: context.ac.accent),
      ),
      error: (e, _) => Center(
        child:
            Text('Error: $e', style: TextStyle(color: context.ac.fgMute)),
      ),
      data: (insights) {
        final i =
            insights as Map<String, dynamic>? ?? const <String, dynamic>{};
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
            Text(
              '${(profile.displayName.isEmpty ? 'YOU' : profile.displayName).toUpperCase()} · SINCE APRIL 2026',
              style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
            ).animate().fadeIn(duration: 250.ms),
            const SizedBox(height: 8),
            Text(
              'Just between us.',
              style: AymaFonts.serif(size: 72, color: context.ac.fg),
            ).animate().fadeIn(duration: 320.ms),
            const SizedBox(height: 12),
            _AymaBanner().animate().fadeIn(duration: 300.ms),
            const SizedBox(height: 16),
            _StoryCard(
              label: 'WHO YOU ARE',
              content: i['about_me']?.toString() ?? '',
              updatedAt: i['about_me_updated_at']?.toString() ?? '',
            )
                .animate(delay: 40.ms)
                .fadeIn(duration: 300.ms)
                .slideY(begin: 0.03, end: 0),
            const SizedBox(height: 10),
            _StoryCard(
              label: "WHAT YOU'RE LOOKING FOR",
              content: i['preferences']?.toString() ?? '',
              updatedAt: i['preferences_updated_at']?.toString() ?? '',
            )
                .animate(delay: 80.ms)
                .fadeIn(duration: 300.ms)
                .slideY(begin: 0.03, end: 0),
            const SizedBox(height: 10),
            _StoryCard(
              label: 'YOUR LIFE RIGHT NOW',
              content: i['context']?.toString() ?? '',
              updatedAt: i['context_updated_at']?.toString() ?? '',
            )
                .animate(delay: 120.ms)
                .fadeIn(duration: 300.ms)
                .slideY(begin: 0.03, end: 0),
            const SizedBox(height: 10),
            _StoryCard(
              label: 'FOR MATCHING',
              content: i['matching']?.toString() ?? '',
              updatedAt: i['matching_updated_at']?.toString() ?? '',
            )
                .animate(delay: 160.ms)
                .fadeIn(duration: 300.ms)
                .slideY(begin: 0.03, end: 0),
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
        color: const Color(0xFF14110F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: context.ac.accent.withValues(alpha: 0.2), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4, right: 10),
            decoration: BoxDecoration(
              color: context.ac.accent,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What I know about you. Only you can see this.',
                  style: AymaFonts.sans(size: 18, color: context.ac.fg),
                ),
                const SizedBox(height: 6),
                Text(
                  'UPDATES EVERY TIME WE TALK',
                  style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
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
  @override
  Widget build(BuildContext context) {
    final hasContent = widget.content.trim().isNotEmpty;
    final relDate = _relativeDate(widget.updatedAt);
    final trimmed = widget.content.trim();

    return GestureDetector(
      onTap: null,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF14110F),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF282118), width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.label,
                    style: AymaFonts.mono(size: 9, color: context.ac.fgMute)),
                if (relDate.isNotEmpty)
                  Text(relDate,
                      style: AymaFonts.mono(
                          size: 9,
                          color: context.ac.fgMute.withValues(alpha: 0.6))),
              ],
            ),
            const SizedBox(height: 12),
            hasContent
                ? Text(trimmed,
                    style: AymaFonts.serif(size: 16, color: context.ac.fg))
                : Text('Nothing here yet — keep chatting with Ayma!',
                    style: AymaFonts.serif(
                        size: 15, color: context.ac.fgMute, italic: true)),
            if (hasContent) ...[
              const SizedBox(height: 14),
              Divider(
                  color: context.ac.lineSoft.withValues(alpha: 0.6),
                  thickness: 0.5,
                  height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.check_box_outline_blank_rounded,
                      size: 13, color: context.ac.fgMute),
                  const SizedBox(width: 6),
                  Text("Disagree? Tell me in our next talk.",
                      style: AymaFonts.mono(size: 9, color: context.ac.fgMute)),
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
    required this.onDeletePhoto,
    required this.onReorderPhotos,
  });

  final UserProfile profile;
  final bool uploadingPhoto;
  final VoidCallback onStartEdit;
  final VoidCallback onAddPhoto;
  final VoidCallback onToggleLocked;
  final ValueChanged<String> onDeletePhoto;
  final ValueChanged<List<String>> onReorderPhotos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final publicAsync = ref.watch(publicProfileProvider(profile.id));

    return publicAsync.when(
      loading: () => Center(
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: context.ac.accent),
      ),
      error: (e, _) => Center(
        child:
            Text('Error: $e', style: TextStyle(color: context.ac.fgMute)),
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
        final location =
            _cityOnly(_first([profile.locationRegion, p['location_region']]));
        final interestedIn = _first([
          profile.matchingPrefs['interested_in'],
          (p['matching_prefs'] as Map?)?['interested_in'],
        ]);
        final job = _first([p['job'], p['occupation']]);
        final company = _first([p['company'], p['employer']]);
        final jobPill = job.isNotEmpty
            ? (company.isNotEmpty ? '$job · $company' : job)
            : '';
        final extraPills = <String>[
          jobPill,
          _first([p['height_text'], p['height']]),
          _first([p['pronouns']]),
          _first([p['religion']]),
          _first([p['relationship_goal']]),
        ].where((e) => e.isNotEmpty).toList();
        final bio = _first([profile.profilePublic, p['profile_public']]);

        return PublicProfileView(
          photos: photos,
          name: name,
          age: age,
          gender: gender,
          location: location,
          interestedIn: interestedIn,
          bio: bio,
          uploadingPhoto: uploadingPhoto,
          onAddPhoto: onAddPhoto,
          onStartEdit: onStartEdit,
          onToggleLocked: onToggleLocked,
          profilePublicLocked: profile.profilePublicLocked,
          showEditControls: true,
          onDeletePhoto: onDeletePhoto,
          onReorderPhotos: onReorderPhotos,
          extraPills: extraPills,
          isOnline: true,
        );
      },
    );
  }
}

// ─── Tab 0 wrapper: Public + completeness bar ─────────────────────────────────

class _PublicTabWithCompleteness extends ConsumerWidget {
  const _PublicTabWithCompleteness({
    required this.profile,
    required this.uploadingPhoto,
    required this.onStartEdit,
    required this.onAddPhoto,
    required this.onToggleLocked,
    required this.onDeletePhoto,
    required this.onReorderPhotos,
  });

  final UserProfile profile;
  final bool uploadingPhoto;
  final VoidCallback onStartEdit;
  final VoidCallback onAddPhoto;
  final VoidCallback onToggleLocked;
  final ValueChanged<String> onDeletePhoto;
  final ValueChanged<List<String>> onReorderPhotos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completenessAsync = ref.watch(profileCompletenessProvider);
    final pct = (completenessAsync.valueOrNull ?? 0.0).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Profile $pct% complete',
                style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: pct / 100.0,
                  minHeight: 3,
                  backgroundColor: context.ac.lineSoft,
                  valueColor: AlwaysStoppedAnimation<Color>(context.ac.accent),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _EditPublicPane(
            profile: profile,
            uploadingPhoto: uploadingPhoto,
            onStartEdit: onStartEdit,
            onAddPhoto: onAddPhoto,
            onToggleLocked: onToggleLocked,
            onDeletePhoto: onDeletePhoto,
            onReorderPhotos: onReorderPhotos,
          ),
        ),
      ],
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
    final h =
        MediaQuery.sizeOf(context).width * 1.1; // slightly taller than square

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section label + count
        Row(
          children: [
            Text('PHOTOS',
                style: AymaFonts.mono(size: 9, color: context.ac.fgMute)),
            if (hasPhotos) ...[
              const SizedBox(width: 8),
              Text('· ${photos.length}',
                  style: AymaFonts.mono(
                      size: 9,
                      color: context.ac.fgMute.withValues(alpha: 0.5))),
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
                              Container(color: context.ac.bgCard),
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
                              color: context.ac.accent,
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
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                width: _page == i ? 18 : 5,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: _page == i
                                      ? context.ac.fg
                                      : context.ac.fg.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              );
                            }),
                          ),
                        ),
                    ],
                  )
                : Container(
                    color: context.ac.bgElev,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: context.ac.accent.withValues(alpha: 0.08),
                            border: Border.all(
                                color: context.ac.accent.withValues(alpha: 0.2),
                                width: 1),
                          ),
                          child: Icon(Icons.photo_library_outlined,
                              color: context.ac.accent, size: 24),
                        ),
                        const SizedBox(height: 14),
                        Text('No photos yet',
                            style: AymaFonts.serif(
                                size: 18, color: context.ac.fg)),
                        const SizedBox(height: 6),
                        Text('Add some to complete your profile',
                            style: AymaFonts.sans(
                                size: 12, color: context.ac.fgMute)),
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
              color: context.ac.bgElev,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.ac.lineSoft, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.uploadingPhoto)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: context.ac.accent),
                  )
                else
                  Icon(Icons.add_photo_alternate_outlined,
                      size: 16, color: context.ac.accent),
                const SizedBox(width: 7),
                Text(
                  widget.uploadingPhoto ? 'Uploading…' : 'Add photo',
                  style: TextStyle(
                      color: context.ac.accent,
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
      backgroundColor: context.ac.bg,
      appBar: AppBar(
        backgroundColor: context.ac.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.ac.fgDim),
          onPressed: onBack,
        ),
        title: Text('Edit profile',
            style: AymaFonts.serif(size: 20, color: context.ac.fg)),
        actions: [
          if (saving)
            Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: context.ac.accent)),
            )
          else
            TextButton(
              onPressed: onSave,
              child: Text('Save',
                  style: AymaFonts.sans(
                      size: 15,
                      color: context.ac.accent,
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
              controller: locationCtrl, label: 'City or region', maxLines: 1),
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
          Text(
            'Only visible to you — Ayma uses this to understand you better.',
            style: TextStyle(color: context.ac.fgMute, fontSize: 11),
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
              color: context.ac.bgElev,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.ac.lineSoft, width: 0.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pause matching',
                          style:
                              AymaFonts.sans(size: 14, color: context.ac.fg)),
                      const SizedBox(height: 2),
                      Text('Hide your profile from new matches',
                          style: AymaFonts.sans(
                              size: 12, color: context.ac.fgMute)),
                    ],
                  ),
                ),
                Switch(
                  value: matchingPaused ?? false,
                  onChanged: onMatchingPausedChanged,
                  activeColor: context.ac.accent,
                  inactiveThumbColor: context.ac.fgMute,
                  inactiveTrackColor: context.ac.lineSoft,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          AymaButton(label: 'Save changes', loading: saving, onPressed: onSave),
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
            style: AymaFonts.mono(size: 9, color: context.ac.fgMute)),
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
              ? context.ac.accent.withValues(alpha: 0.15)
              : context.ac.bgElev,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? context.ac.accent.withValues(alpha: 0.5)
                : context.ac.lineSoft,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? context.ac.accent : context.ac.fgDim,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
