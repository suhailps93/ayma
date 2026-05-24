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

// ── Profile screen ─────────────────────────────────────────────────────────────

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _editing = false;
  bool _saving = false;
  bool _uploadingPhoto = false;
  final _bioCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _agentNameCtrl = TextEditingController();
  String? _voicePref;
  bool? _matchingPaused;
  final ImagePicker _imagePicker = ImagePicker();

  void _startEdit(UserProfile profile) {
    _bioCtrl.text = profile.profilePublic ?? '';
    _notesCtrl.text = profile.profilePrivate ?? '';
    _agentNameCtrl.text = profile.agentName;
    _voicePref = profile.voicePreference;
    _matchingPaused = profile.matchingPaused;
    setState(() => _editing = true);
  }

  Future<void> _save(UserProfile profile) async {
    setState(() => _saving = true);
    try {
      await FirestoreService.updateProfile({
        'profile_public': _bioCtrl.text.trim(),
        'profile_private': _notesCtrl.text.trim(),
        'agent_name': _agentNameCtrl.text.trim(),
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
        const SnackBar(
            content: Text('Photo uploaded. Ayma is processing it now.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _toggleLocked(UserProfile profile) async {
    final newVal = !profile.profilePublicLocked;
    try {
      await FirestoreService.updateProfile({'profile_public_locked': newVal});
      ref.invalidate(profileProvider);
    } catch (_) {}
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
      body: profileAsync.when(
        loading: () => const Center(
          child:
              CircularProgressIndicator(strokeWidth: 1.5, color: AymaColors.accent),
        ),
        error: (e, _) => Center(
          child: Text('Error loading profile',
              style: TextStyle(color: AymaColors.fgDim)),
        ),
        data: (profile) {
          if (profile == null) {
            return Center(
              child: Text('No profile found',
                  style: TextStyle(color: AymaColors.fgDim)),
            );
          }
          if (_editing) {
            return _EditView(
              profile: profile,
              bioCtrl: _bioCtrl,
              notesCtrl: _notesCtrl,
              agentNameCtrl: _agentNameCtrl,
              voicePref: _voicePref ?? profile.voicePreference,
              matchingPaused: _matchingPaused ?? profile.matchingPaused,
              saving: _saving,
              onVoiceChange: (v) => setState(() => _voicePref = v),
              onPauseChange: (v) => setState(() => _matchingPaused = v),
              onSave: () => _save(profile),
              onCancel: () => setState(() => _editing = false),
            );
          }
          return _ProfileView(
            profile: profile,
            uploadingPhoto: _uploadingPhoto,
            onEdit: () => _startEdit(profile),
            onAddPhoto: () => _pickAndUploadPhoto(profile),
            onToggleLocked: () => _toggleLocked(profile),
          );
        },
      ),
    );
  }
}

// ── Profile view ───────────────────────────────────────────────────────────────

class _ProfileView extends ConsumerWidget {
  final UserProfile profile;
  final bool uploadingPhoto;
  final VoidCallback onEdit;
  final VoidCallback onAddPhoto;
  final VoidCallback onToggleLocked;

  const _ProfileView({
    required this.profile,
    required this.uploadingPhoto,
    required this.onEdit,
    required this.onAddPhoto,
    required this.onToggleLocked,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final publicAsync = ref.watch(publicProfileProvider(profile.id));
    final insightsAsync = ref.watch(insightsProvider);
    final pub = publicAsync.valueOrNull ?? const <String, dynamic>{};
    final insights = insightsAsync.valueOrNull ?? const <String, String>{};

    final photos = ((pub['photos'] as List?) ?? const [])
        .whereType<String>()
        .where((u) => u.isNotEmpty)
        .toList();

    final name = _first([pub['display_name'], profile.displayName, 'You']);
    final age = _age([pub['age'], profile.age]);
    final gender = _first([pub['gender'], profile.gender]);
    final location = _cityOnly(_first([pub['location_region'], profile.locationRegion]));
    final interestedIn =
        _first([(pub['matching_prefs'] as Map?)?['interested_in'], profile.matchingPrefs['interested_in']]);
    final bio = _first([pub['profile_public'], profile.profilePublic]);

    return CustomScrollView(
      slivers: [
        // ── Photo hero ──────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _PhotoHero(
            photos: photos,
            name: name,
            age: age,
            loading: publicAsync.isLoading && photos.isEmpty,
            onSettings: () => context.push('/settings'),
            onAddPhoto: onAddPhoto,
            uploadingPhoto: uploadingPhoto,
          ).animate().fadeIn(duration: 300.ms),
        ),

        // ── Public identity card ────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: _PublicIdentityCard(
              name: name,
              age: age,
              gender: gender,
              location: location,
              interestedIn: interestedIn,
              isLocked: profile.profilePublicLocked,
              onToggleLocked: onToggleLocked,
              onEdit: onEdit,
            ),
          ).animate(delay: 80.ms).fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
        ),

        // ── Public bio ──────────────────────────────────────────────────────
        if (bio.isNotEmpty || !profile.profilePublicLocked)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _PublicBioCard(
                bio: bio,
                isLocked: profile.profilePublicLocked,
                onAskAyma: () => _showAskAymaSnack(context),
              ),
            ).animate(delay: 140.ms).fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
          ),

        // ── Public story snippet (about_me) ─────────────────────────────────
        if ((insights['about_me'] ?? '').trim().isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _PublicStorySnippet(
                text: insights['about_me']!,
                onAskAyma: () => _showAskAymaSnack(context),
              ),
            ).animate(delay: 180.ms).fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
          ),

        // ── Private divider ─────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
            child: _PrivateDivider(),
          ).animate(delay: 220.ms).fadeIn(duration: 300.ms),
        ),

        // ── Story wiki cards ────────────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _WikiCard(
                title: 'About You',
                subtitle: 'Who you are',
                icon: Icons.person_outline_rounded,
                content: insights['about_me'] ?? '',
                emptyHint: 'Talk to Ayma and she\'ll start building a picture of who you are.',
                delay: 240.ms,
              ),
              const SizedBox(height: 10),
              _WikiCard(
                title: 'What You\'re Looking For',
                subtitle: 'Your ideal match',
                icon: Icons.favorite_border_rounded,
                content: insights['preferences'] ?? '',
                emptyHint: 'Tell Ayma what you\'re looking for in a partner.',
                delay: 280.ms,
              ),
              const SizedBox(height: 10),
              _WikiCard(
                title: 'Right Now',
                subtitle: 'Your current chapter',
                icon: Icons.wb_sunny_outlined,
                content: insights['context'] ?? '',
                emptyHint: 'Ayma will capture what\'s going on in your life right now.',
                delay: 320.ms,
              ),
              const SizedBox(height: 10),
              _WikiCard(
                title: 'Public Profile',
                subtitle: 'What others see about you',
                icon: Icons.public_outlined,
                content: insights['public_profile'] ?? bio,
                emptyHint: 'Talk to Ayma to build your public profile text.',
                delay: 360.ms,
              ),
              const SizedBox(height: 10),
              _WikiCard(
                title: 'Your Photos',
                subtitle: 'How Ayma sees your photos',
                icon: Icons.photo_library_outlined,
                content: insights['media'] ?? '',
                emptyHint: 'Upload photos and Ayma will describe them for matching.',
                delay: 400.ms,
                isMedia: true,
              ),
              const SizedBox(height: 10),
            ]),
          ),
        ),

        // ── Open full story link ────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: GestureDetector(
              onTap: () => context.go('/insights'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  color: AymaColors.bgElev,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Open full story',
                        style: TextStyle(
                          color: AymaColors.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        )),
                    const SizedBox(width: 6),
                    Icon(Icons.arrow_forward_ios_rounded,
                        size: 11, color: AymaColors.accent.withValues(alpha: 0.7)),
                  ],
                ),
              ),
            ),
          ).animate(delay: 420.ms).fadeIn(duration: 300.ms),
        ),

        // ── Private notes ───────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _PrivateNotesCard(
              notes: profile.profilePrivate,
              onEdit: onEdit,
            ),
          ).animate(delay: 460.ms).fadeIn(duration: 300.ms).slideY(begin: 0.04, end: 0),
        ),

        // ── Matching preferences ────────────────────────────────────────────
        if (profile.matchingPrefs.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _PrefsCard(prefs: profile.matchingPrefs),
            ).animate(delay: 500.ms).fadeIn(duration: 300.ms).slideY(begin: 0.04, end: 0),
          ),

        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }

  void _showAskAymaSnack(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Tell Ayma what to change in your next conversation.')),
    );
  }
}

// ── Photo hero ─────────────────────────────────────────────────────────────────

class _PhotoHero extends StatefulWidget {
  final List<String> photos;
  final String name;
  final int? age;
  final bool loading;
  final VoidCallback onSettings;
  final VoidCallback onAddPhoto;
  final bool uploadingPhoto;

  const _PhotoHero({
    required this.photos,
    required this.name,
    required this.age,
    required this.loading,
    required this.onSettings,
    required this.onAddPhoto,
    required this.uploadingPhoto,
  });

  @override
  State<_PhotoHero> createState() => _PhotoHeroState();
}

class _PhotoHeroState extends State<_PhotoHero> {
  final _ctrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height * 0.58;
    final hasPhotos = widget.photos.isNotEmpty;

    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Photos / fallback
          if (hasPhotos)
            PageView.builder(
              controller: _ctrl,
              itemCount: widget.photos.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) => Image.network(
                widget.photos[i],
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _HeroFallback(
                    name: widget.name, loading: false),
              ),
            )
          else
            _HeroFallback(name: widget.name, loading: widget.loading),

          // Bottom gradient + name
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.45, 1.0],
                  colors: [Colors.transparent, Color(0xDD131210)],
                ),
              ),
            ),
          ),

          // Name / age overlay
          Positioned(
            left: 20,
            right: 20,
            bottom: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasPhotos && widget.photos.length > 1) ...[
                  Row(
                    children: List.generate(
                      widget.photos.length,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.only(right: 4),
                        width: _page == i ? 20 : 5,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _page == i
                              ? AymaColors.fg
                              : AymaColors.fg.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      widget.name,
                      style: AymaFonts.serif(size: 40, color: AymaColors.fg),
                    ),
                    if (widget.age != null) ...[
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${widget.age}',
                          style: AymaFonts.serif(
                              size: 26, color: AymaColors.fg.withValues(alpha: 0.7)),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // Top controls
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _HeroIconBtn(
                      icon: Icons.settings_outlined,
                      onTap: widget.onSettings,
                    ),
                    const SizedBox(width: 8),
                    _HeroAddPhotoBtn(
                      uploading: widget.uploadingPhoto,
                      onTap: widget.onAddPhoto,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroFallback extends StatelessWidget {
  final String name;
  final bool loading;
  const _HeroFallback({required this.name, required this.loading});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E1B14), Color(0xFF131210)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: loading
            ? const CircularProgressIndicator(
                strokeWidth: 1.5, color: AymaColors.accent)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AymaColors.accent.withValues(alpha: 0.1),
                      border: Border.all(
                          color: AymaColors.accent.withValues(alpha: 0.2),
                          width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: TextStyle(
                          color: AymaColors.accent,
                          fontSize: 38,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('No photos yet',
                      style: AymaFonts.serif(size: 22, color: AymaColors.fg)),
                  const SizedBox(height: 6),
                  Text('Tap + to add photos',
                      style: TextStyle(color: AymaColors.fgMute, fontSize: 13)),
                ],
              ),
      ),
    );
  }
}

class _HeroIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _HeroIconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.12), width: 0.5),
        ),
        child: Icon(icon, size: 17, color: AymaColors.fg),
      ),
    );
  }
}

class _HeroAddPhotoBtn extends StatelessWidget {
  final bool uploading;
  final VoidCallback onTap;
  const _HeroAddPhotoBtn({required this.uploading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: uploading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.12), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (uploading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AymaColors.fg),
              )
            else
              const Icon(Icons.add_photo_alternate_outlined,
                  size: 15, color: AymaColors.fg),
            const SizedBox(width: 6),
            Text(uploading ? 'Uploading...' : 'Add photo',
                style:
                    const TextStyle(color: AymaColors.fg, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ── Public identity card ───────────────────────────────────────────────────────

class _PublicIdentityCard extends StatelessWidget {
  final String name;
  final int? age;
  final String? gender;
  final String? location;
  final String? interestedIn;
  final bool isLocked;
  final VoidCallback onToggleLocked;
  final VoidCallback onEdit;

  const _PublicIdentityCard({
    required this.name,
    required this.age,
    required this.gender,
    required this.location,
    required this.interestedIn,
    required this.isLocked,
    required this.onToggleLocked,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (age != null) '$age',
      if (gender != null && gender!.isNotEmpty) gender!,
      if (interestedIn != null && interestedIn!.isNotEmpty)
        'Interested in $interestedIn',
      if (location != null && location!.isNotEmpty) location!,
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(name,
                    style: AymaFonts.serif(size: 32, color: AymaColors.fg)),
              ),
              const SizedBox(width: 12),
              // Edit button
              GestureDetector(
                onTap: onEdit,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AymaColors.bgCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_outlined,
                          size: 13, color: AymaColors.fgDim),
                      const SizedBox(width: 5),
                      Text('Edit',
                          style: TextStyle(
                              color: AymaColors.fgDim, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(meta,
                style:
                    const TextStyle(color: AymaColors.fgMute, fontSize: 14, height: 1.4)),
          ],
          const SizedBox(height: 14),
          // AI / locked toggle
          GestureDetector(
            onTap: onToggleLocked,
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isLocked
                        ? Colors.green.shade900.withValues(alpha: 0.4)
                        : AymaColors.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isLocked
                          ? Colors.green.shade600.withValues(alpha: 0.4)
                          : AymaColors.accent.withValues(alpha: 0.3),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isLocked
                            ? Icons.lock_outline_rounded
                            : Icons.auto_awesome_outlined,
                        size: 11,
                        color: isLocked
                            ? Colors.green.shade400
                            : AymaColors.accent,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isLocked ? 'User edited' : 'AI written',
                        style: TextStyle(
                          color: isLocked
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
                  isLocked ? 'Tap to let Ayma update' : 'Tap to lock',
                  style: TextStyle(color: AymaColors.fgMute, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Public bio card ────────────────────────────────────────────────────────────

class _PublicBioCard extends StatelessWidget {
  final String bio;
  final bool isLocked;
  final VoidCallback onAskAyma;

  const _PublicBioCard({
    required this.bio,
    required this.isLocked,
    required this.onAskAyma,
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
              Text('PUBLIC BIO',
                  style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
              const Spacer(),
              GestureDetector(
                onTap: onAskAyma,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AymaColors.bgCard,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome_outlined,
                          size: 11, color: AymaColors.fgMute),
                      const SizedBox(width: 4),
                      Text('Ask Ayma to edit',
                          style: TextStyle(
                              color: AymaColors.fgMute, fontSize: 10)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          bio.isNotEmpty
              ? Text(bio,
                  style:
                      const TextStyle(color: AymaColors.fg, fontSize: 14, height: 1.65))
              : Text(
                  'No public bio yet. Talk to Ayma to build your profile.',
                  style: const TextStyle(
                      color: AymaColors.fgMute,
                      fontSize: 13,
                      height: 1.6,
                      fontStyle: FontStyle.italic),
                ),
        ],
      ),
    );
  }
}

// ── Public story snippet ───────────────────────────────────────────────────────

class _PublicStorySnippet extends StatelessWidget {
  final String text;
  final VoidCallback onAskAyma;

  const _PublicStorySnippet({required this.text, required this.onAskAyma});

  @override
  Widget build(BuildContext context) {
    final preview = text.trim().split('\n').first.trim();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AymaColors.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AymaColors.accent.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AymaColors.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text('ABOUT YOU',
                    style: AymaFonts.mono(
                        size: 8, color: AymaColors.accent.withValues(alpha: 0.7))),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onAskAyma,
                child: Icon(Icons.edit_outlined,
                    size: 14, color: AymaColors.fgMute),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            preview.isNotEmpty ? preview : text.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(color: AymaColors.fg, fontSize: 14, height: 1.6),
          ),
        ],
      ),
    );
  }
}

// ── Private divider ────────────────────────────────────────────────────────────

class _PrivateDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: Container(
                height: 0.5, color: AymaColors.lineSoft.withValues(alpha: 0.6))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 11, color: AymaColors.fgMute),
              const SizedBox(width: 6),
              Text('YOUR STORY · PRIVATE',
                  style: AymaFonts.mono(size: 8, color: AymaColors.fgMute)),
            ],
          ),
        ),
        Expanded(
            child: Container(
                height: 0.5, color: AymaColors.lineSoft.withValues(alpha: 0.6))),
      ],
    );
  }
}

// ── Wiki card (expandable) ─────────────────────────────────────────────────────

class _WikiCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final String content;
  final String emptyHint;
  final Duration delay;
  final bool isMedia;

  const _WikiCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.content,
    required this.emptyHint,
    this.delay = Duration.zero,
    this.isMedia = false,
  });

  @override
  State<_WikiCard> createState() => _WikiCardState();
}

class _WikiCardState extends State<_WikiCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hasContent = widget.content.trim().isNotEmpty;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: HudPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: AymaColors.gold.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AymaColors.gold.withValues(alpha: 0.2),
                          width: 0.5),
                    ),
                    child: Icon(widget.icon,
                        size: 15,
                        color: hasContent
                            ? AymaColors.gold
                            : AymaColors.textTertiary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            color: hasContent
                                ? AymaColors.textPrimary
                                : AymaColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                              color: AymaColors.textTertiary,
                              fontSize: 10,
                              letterSpacing: 0.2),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: AymaColors.textTertiary,
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              Container(height: 0.5, color: AymaColors.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: hasContent
                    ? Text(
                        widget.content.trim(),
                        style: const TextStyle(
                            color: AymaColors.textPrimary,
                            fontSize: 13,
                            height: 1.65,
                            letterSpacing: 0.1),
                      )
                    : Text(
                        widget.emptyHint,
                        style: const TextStyle(
                            color: AymaColors.textTertiary,
                            fontSize: 12,
                            height: 1.6,
                            fontStyle: FontStyle.italic),
                      ),
              ),
            ],
          ],
        ),
      )
          .animate(delay: widget.delay)
          .fadeIn(duration: 300.ms)
          .slideY(begin: 0.04, end: 0),
    );
  }
}

// ── Private notes card ─────────────────────────────────────────────────────────

class _PrivateNotesCard extends StatelessWidget {
  final String? notes;
  final VoidCallback onEdit;

  const _PrivateNotesCard({required this.notes, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final hasNotes = notes?.trim().isNotEmpty == true;

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
              Text('PRIVATE NOTES',
                  style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
              const Spacer(),
              GestureDetector(
                onTap: onEdit,
                child: Icon(Icons.edit_outlined,
                    size: 14, color: AymaColors.fgMute),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Only visible to you — Ayma uses this to understand you better.',
              style: TextStyle(color: AymaColors.fgMute, fontSize: 11)),
          const SizedBox(height: 12),
          Text(
            hasNotes ? notes! : 'No private notes yet.',
            style: TextStyle(
              color: hasNotes ? AymaColors.fg : AymaColors.fgMute,
              fontSize: 13,
              height: 1.6,
              fontStyle: hasNotes ? FontStyle.normal : FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Preferences card ───────────────────────────────────────────────────────────

class _PrefsCard extends StatelessWidget {
  final Map<String, dynamic> prefs;
  const _PrefsCard({required this.prefs});

  String _label(String key, dynamic value) {
    final label = key.replaceAll('_', ' ');
    if (value is bool) return '$label: ${value ? 'yes' : 'no'}';
    if (value is List) return '$label: ${value.join(', ')}';
    return '$label: $value';
  }

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
          Text('MATCHING PREFERENCES',
              style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: prefs.entries
                .where((e) => e.value != null && e.value.toString().isNotEmpty)
                .map((e) => _Chip(_label(e.key, e.value)))
                .toList(),
          ),
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
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AymaColors.bgCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child:
            Text(label, style: TextStyle(color: AymaColors.fgDim, fontSize: 12)),
      );
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
        SafeArea(
          bottom: false,
          child: Row(
            children: [
              GestureDetector(
                onTap: onCancel,
                child: Icon(Icons.arrow_back_rounded, color: AymaColors.fgDim),
              ),
              const SizedBox(width: 14),
              Text('Edit profile',
                  style: AymaFonts.serif(size: 22, color: AymaColors.fg)),
            ],
          ),
        ),
        const SizedBox(height: 28),

        _FieldLabel('Agent name'),
        const SizedBox(height: 8),
        AymaTextField(controller: agentNameCtrl, label: 'e.g. Ayma', maxLines: 1),

        const SizedBox(height: 20),

        _FieldLabel('Voice'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _kVoiceOptions
              .map((v) => GestureDetector(
                    onTap: () => onVoiceChange(v),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
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
                          color: voicePref == v
                              ? AymaColors.accent
                              : AymaColors.fgDim,
                          fontSize: 13,
                          fontWeight: voicePref == v
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ))
              .toList(),
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
                            TextStyle(color: AymaColors.fg, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text('Hide your profile from new matches',
                        style: TextStyle(
                            color: AymaColors.fgMute, fontSize: 12)),
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

// ── Field label ────────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
      );
}

// ── Helpers ────────────────────────────────────────────────────────────────────

String _first(Iterable<dynamic> values) {
  for (final v in values) {
    final s = v?.toString().trim() ?? '';
    if (s.isNotEmpty) return s;
  }
  return '';
}

int? _age(Iterable<dynamic> values) {
  for (final v in values) {
    if (v is int) return v;
    if (v is num) return v.toInt();
  }
  return null;
}

String _cityOnly(String region) {
  if (region.isEmpty) return '';
  return region.split(',').first.trim();
}
