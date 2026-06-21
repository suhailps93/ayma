// Multi-step onboarding: community selection, demographics, location, prefs, and photos.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/community_profile.dart';
import '../../providers/providers.dart';
import '../../services/api_service.dart';
import '../../services/backend_service.dart';
import '../../theme.dart';
import '../../utils/distance_units.dart';
import '../../widgets/ayma_button.dart';

// ── Orb painter (same as auth screen) ────────────────────────────────────────

class _OrbPainter extends CustomPainter {
  final double breathe; // 0.0 → 1.0
  const _OrbPainter(this.breathe);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final baseR = size.width * 0.38;
    final r = baseR * (0.93 + 0.07 * breathe);

    canvas.drawCircle(
      Offset(cx, cy),
      r * 1.35,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x18C48312),
            const Color(0x08C48312),
            Colors.transparent,
          ],
        ).createShader(
          Rect.fromCircle(center: Offset(cx, cy), radius: r * 1.35),
        ),
    );

    canvas.drawCircle(
      Offset(cx, cy),
      r * 1.12,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0x22C48312)
        ..strokeWidth = 0.5,
    );

    final spherePaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.4),
        radius: 0.9,
        colors: const [
          Color(0xFFEDD5A8),
          Color(0xFFC48312),
          Color(0xFF6B3A0C),
          Color(0xFF2A1505),
        ],
        stops: const [0.0, 0.35, 0.68, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawCircle(Offset(cx, cy), r, spherePaint);

    final hlR = r * 0.28;
    canvas.drawCircle(
      Offset(cx - r * 0.25, cy - r * 0.28),
      hlR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.35),
            Colors.transparent,
          ],
        ).createShader(
          Rect.fromCircle(
            center: Offset(cx - r * 0.25, cy - r * 0.28),
            radius: hlR,
          ),
        ),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.breathe != breathe;
}

class _BreathingOrb extends StatefulWidget {
  final double size;
  const _BreathingOrb({this.size = 160});

  @override
  State<_BreathingOrb> createState() => _BreathingOrbState();
}

class _BreathingOrbState extends State<_BreathingOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (_, __) => CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _OrbPainter(_anim.value),
        ),
      );
}

// ── Main screen ───────────────────────────────────────────────────────────────

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  // 0=welcome, 1=community select, 2=about you, 3=preferences, 4=photos
  int _step = 0;
  bool _saving = false;

  // Step 1 – community
  CommunityProfile? _communityProfile;

  // Step 2 – about you
  final _nameCtrl = TextEditingController();
  String? _gender;
  int _age = 28;

  // Step 3 – preferences
  String? _interestedIn;
  int _minAge = 24;
  int _maxAge = 38;
  String _locationText = '';
  final _locationCtrl = TextEditingController();
  bool _locationLoading = false;
  List<String> _suggestions = [];
  Timer? _debounce;
  bool _locationExpanded = false;
  int _locationRequestId = 0;
  double? _locationLat;
  double? _locationLng;

  // Step 4 – photos
  final List<String> _photoUrls = [];
  bool _uploadingPhoto = false;

  static const List<String> _seedLocations = [
    'San Francisco, CA',
    'San Jose, CA',
    'Oakland, CA',
    'Los Angeles, CA',
    'San Diego, CA',
    'Seattle, WA',
    'New York, NY',
    'Austin, TX',
    'Chicago, IL',
    'Boston, MA',
  ];

  String _normalizedLocation(String input) =>
      input.trim().replaceAll(RegExp(r'\s+'), ' ');

  void _setLocationText(String value, {bool updateController = false}) {
    final normalized = _normalizedLocation(value);
    _locationText = normalized;
    if (updateController && _locationCtrl.text != normalized) {
      _locationCtrl.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
  }

  void _syncLocationFromController() {
    final normalized = _normalizedLocation(_locationCtrl.text);
    final nextSuggestions = _buildLocationSuggestions(normalized);
    if (_locationText != normalized ||
        !_sameSuggestions(_suggestions, nextSuggestions)) {
      setState(() {
        _locationText = normalized;
        _suggestions = nextSuggestions;
      });
    }
  }

  bool _sameSuggestions(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<String> _buildLocationSuggestions(String input) {
    final q = input.toLowerCase().trim();
    if (q.isEmpty) return _seedLocations.take(5).toList();
    return _seedLocations
        .where((c) => c.toLowerCase().contains(q))
        .take(6)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _locationCtrl.addListener(_syncLocationFromController);

    // Synchronously check if cached profile/preboarding values exist to avoid flashing Step 0
    final preSeen = ref.read(preboardingSeenProvider).valueOrNull ?? false;
    final profile = ref.read(profileProvider).valueOrNull;

    if (profile != null) {
      if (profile.displayName.isNotEmpty) {
        _nameCtrl.text = profile.displayName;
      }
      if (profile.gender != null && profile.gender!.isNotEmpty) {
        _gender = profile.gender;
      }
      if (profile.age != null) {
        _age = profile.age!;
      }
      final prefs = profile.matchingPrefs;
      if (prefs.containsKey('interested_in')) {
        _interestedIn = prefs['interested_in'] as String?;
      }
      if (prefs.containsKey('age_min')) {
        _minAge = prefs['age_min'] as int;
      }
      if (prefs.containsKey('age_max')) {
        _maxAge = prefs['age_max'] as int;
      }
      if (profile.locationRegion != null && profile.locationRegion!.isNotEmpty) {
        _setLocationText(profile.locationRegion!, updateController: true);
      }
      if (profile.communityProfile.isNotEmpty) {
        _communityProfile = CommunityProfiles.forId(profile.communityProfile);
      }
    }

    if (preSeen) {
      if (profile != null) {
        final hasCommunity = profile.communityProfile.isNotEmpty && profile.communityProfile != 'dating_standard';
        final hasAboutYou = profile.displayName.isNotEmpty && profile.gender != null;
        final hasPrefs = (profile.matchingPrefs['interested_in'] as String?)?.isNotEmpty == true;

        if (hasAboutYou && hasPrefs) {
          _step = 4;
        } else if (hasAboutYou) {
          _step = 3;
        } else if (hasCommunity) {
          _step = 2;
        } else {
          _step = 1;
        }
      } else {
        _step = 1;
      }
    } else {
      _step = 0;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        // Async fetch to verify latest backend values
        final alreadySeen = await ref.read(preboardingSeenProvider.future);
        final latestProfile = await ref.read(profileProvider.future);
        if (!mounted) return;

        if (latestProfile != null && latestProfile.onboardingComplete) {
          if (mounted) context.go('/chat');
          return;
        }

        setState(() {
          if (latestProfile != null) {
            if (_nameCtrl.text.isEmpty && latestProfile.displayName.isNotEmpty) {
              _nameCtrl.text = latestProfile.displayName;
            }
            _gender ??= (latestProfile.gender?.isNotEmpty == true ? latestProfile.gender : null);
            if (latestProfile.age != null) {
              _age = latestProfile.age!;
            }
            final prefs = latestProfile.matchingPrefs;
            _interestedIn ??= prefs['interested_in'] as String?;
            if (prefs.containsKey('age_min')) {
              _minAge = prefs['age_min'] as int;
            }
            if (prefs.containsKey('age_max')) {
              _maxAge = prefs['age_max'] as int;
            }
            if (_locationCtrl.text.isEmpty && latestProfile.locationRegion != null && latestProfile.locationRegion!.isNotEmpty) {
              _setLocationText(latestProfile.locationRegion!, updateController: true);
            }
            if (_communityProfile == null && latestProfile.communityProfile.isNotEmpty) {
              _communityProfile = CommunityProfiles.forId(latestProfile.communityProfile);
            }
          }
        });

        setState(() {
          if (alreadySeen && _step == 0) {
            int nextStep = 1;
            if (latestProfile != null) {
              final hasCommunity = latestProfile.communityProfile.isNotEmpty && latestProfile.communityProfile != 'dating_standard';
              final hasAboutYou = latestProfile.displayName.isNotEmpty && latestProfile.gender != null;
              final hasPrefs = (latestProfile.matchingPrefs['interested_in'] as String?)?.isNotEmpty == true;

              if (hasAboutYou && hasPrefs) {
                nextStep = 4;
              } else if (hasAboutYou) {
                nextStep = 3;
              } else if (hasCommunity) {
                nextStep = 2;
              }
            }
            _step = nextStep;
          }
        });
        unawaited(ApiService.markPreboardingSeen());
      } catch (e) {
        debugPrint('DEBUG: Error loading onboarding values: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to load profile details: $e')),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _locationCtrl.removeListener(_syncLocationFromController);
    _nameCtrl.dispose();
    _locationCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _next() {
    if (_step < 4) {
      setState(() {
        _step++;
        if (_step == 3) _detectLocation();
      });
    } else {
      _save();
    }
  }

  Future<void> _detectLocation() async {
    // Check and request permission before attempting GPS.
    // If denied, auto-expand the text field so the user can search manually.
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      if (mounted) setState(() => _locationExpanded = true);
      return;
    }

    final requestId = ++_locationRequestId;
    final startedWith = _normalizedLocation(_locationCtrl.text);
    setState(() => _locationLoading = true);
    try {
      final pos = await Geolocator.getCurrentPosition();
      _locationLat = pos.latitude;
      _locationLng = pos.longitude;
      var location =
          '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
      try {
        final marks =
            await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (marks.isNotEmpty) {
          final p = marks.first;
          final city = (p.locality ?? p.subAdministrativeArea ?? '').trim();
          final state = (p.administrativeArea ?? '').trim();
          final country = (p.country ?? '').trim();
          final parts =
              [city, state, country].where((s) => s.isNotEmpty).toList();
          if (parts.isNotEmpty) location = parts.join(', ');
        }
      } catch (_) {}
      if (!mounted) return;
      final currentInput = _normalizedLocation(_locationCtrl.text);
      final canApply = requestId == _locationRequestId &&
          (currentInput.isEmpty || currentInput == startedWith);
      if (!canApply) return;
      setState(() {
        _setLocationText(location, updateController: true);
        _suggestions = _buildLocationSuggestions(location);
      });
    } catch (_) {
      // GPS failed after permission granted — fall back to manual search
      if (mounted) setState(() => _locationExpanded = true);
    }
    if (mounted && requestId == _locationRequestId) {
      setState(() => _locationLoading = false);
    }
  }

  void _onLocationChanged(String val) {
    final normalized = _normalizedLocation(val);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () async {
      if (!mounted || normalized.length < 3) return;
      try {
        final resolved = await locationFromAddress(normalized);
        if (!mounted) return;
        if (resolved.isNotEmpty) {
          _locationLat = resolved.first.latitude;
          _locationLng = resolved.first.longitude;
        }
      } catch (_) {}
    });
    setState(() {
      _setLocationText(val);
      _suggestions = _buildLocationSuggestions(normalized);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final voiceDefaults = ApiService.deriveVoiceDefaults(
        gender: _gender,
        locationRegion: _normalizedLocation(_locationCtrl.text),
      );
      final communityId =
          (_communityProfile ?? CommunityProfiles.datingWestern).id;
      await ApiService.updateProfile({
        'display_name': _nameCtrl.text.trim(),
        'age': _age,
        'gender': _gender,
        'voice_preference': voiceDefaults['voice_gender'],
        'voice_accent': voiceDefaults['accent_locale'],
        'voice_settings': voiceDefaults,
        'community_profile': communityId,
        'matching_prefs': {
          'interested_in': _interestedIn,
          'age_min': _minAge,
          'age_max': _maxAge,
        },
        'location_region': _normalizedLocation(_locationCtrl.text),
        if (_locationLat != null && _locationLng != null)
          'location_coords': {
            'lat': _locationLat,
            'lng': _locationLng,
          },
        'onboarding_complete': true,
      });
      await ApiService.markOnboardingCompleteLocal();
      await ApiService.initializeQuestions(
        alreadyAnswered: {'name', 'age', 'gender', 'interested_in', 'location'},
      );
      ref.invalidate(profileProvider);
      ref.invalidate(onboardingStatusProvider);
      await ref.read(onboardingStatusProvider.future);
      if (mounted) context.go('/chat');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  bool get _canProceed {
    switch (_step) {
      case 0:
        return true;
      case 1:
        return _communityProfile != null;
      case 2:
        return _nameCtrl.text.trim().isNotEmpty && _gender != null;
      case 3:
        return _interestedIn != null;
      case 4:
        return !_uploadingPhoto;
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AymaColors.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            if (_step > 0)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                child: Row(
                  children: List.generate(
                    4,
                    (i) => Expanded(
                      child: Container(
                        height: 2,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: i < _step
                              ? AymaColors.accent
                              : AymaColors.lineSoft,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              const SizedBox(height: 18),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.04, 0),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(parent: anim, curve: Curves.easeOut),
                    ),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _buildStep(),
                ),
              ),
            ),
            _buildBottom(),
          ],
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _WelcomeStep(onHowItWorks: _showHowItWorks);
      case 1:
        return _CommunityStep(
          selected: _communityProfile,
          onSelect: (c) => setState(() => _communityProfile = c),
        );
      case 2:
        return _AboutYouStep(
          nameCtrl: _nameCtrl,
          gender: _gender,
          age: _age,
          onChanged: () => setState(() {}),
          onGenderSelect: (v) => setState(() => _gender = v),
          onAgeChanged: (v) => setState(() => _age = v),
        );
      case 3:
        return _PreferencesStep(
          interestedIn: _interestedIn,
          minAge: _minAge,
          maxAge: _maxAge,
          locationText: _locationText,
          locationCtrl: _locationCtrl,
          locationLoading: _locationLoading,
          locationExpanded: _locationExpanded,
          suggestions: _suggestions,
          onInterestSelect: (v) => setState(() => _interestedIn = v),
          onRangeChange: (lo, hi) => setState(() {
            _minAge = lo;
            _maxAge = hi;
          }),
          onLocationTap: () => setState(() {
            _locationExpanded = !_locationExpanded;
            if (_locationExpanded) {
              _suggestions = _buildLocationSuggestions(_locationCtrl.text);
              if (_locationCtrl.text.trim().isEmpty) _detectLocation();
            } else {
              _suggestions = [];
            }
          }),
          onLocationChanged: _onLocationChanged,
          onSuggestionTap: (s) => setState(() {
            _setLocationText(s, updateController: true);
            _suggestions = [];
            _locationExpanded = false;
          }),
          onDetect: _detectLocation,
          countryCode: Localizations.localeOf(context).countryCode,
        );
      case 4:
        return _PhotoStep(
          photoUrls: _photoUrls,
          uploading: _uploadingPhoto,
          onAdd: _pickAndUploadPhoto,
          onSetPrimary: _setPhotoAsPrimary,
          onDelete: _deletePhoto,
        );
      default:
        return const SizedBox();
    }
  }

  void _setPhotoAsPrimary(int index) {
    if (index <= 0 || index >= _photoUrls.length) return;
    setState(() {
      final url = _photoUrls.removeAt(index);
      _photoUrls.insert(0, url);
    });
    unawaited(ApiService.updatePhotoOrder(_photoUrls));
  }

  void _deletePhoto(int index) {
    if (index < 0 || index >= _photoUrls.length) return;
    final url = _photoUrls[index];
    setState(() => _photoUrls.removeAt(index));
    unawaited(ApiService.deleteMediaByUrl(url));
    unawaited(ApiService.updatePhotoOrder(_photoUrls));
  }

  Future<void> _pickAndUploadPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 85, limit: 6);
    if (picked.isEmpty || !mounted) return;
    setState(() => _uploadingPhoto = true);
    try {
      for (final xfile in picked) {
        final bytes = await xfile.readAsBytes();
        final url = await BackendService.uploadMedia(bytes, xfile.name);
        await ApiService.saveMediaRecord(photoUrl: url);
        if (mounted) setState(() => _photoUrls.add(url));
      }
      // Ask backend to analyze uploaded photos for face/appearance context
      if (_photoUrls.isNotEmpty) {
        unawaited(ApiService.analyzePhotos(_photoUrls));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
    if (mounted) setState(() => _uploadingPhoto = false);
  }

  Widget _buildBottom() {
    if (_step == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
        child: Column(
          children: [
            _LargeButton(
              label: "Let's start",
              onPressed: _next,
            ),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _showHowItWorks,
              child: Text(
                'How does this work?',
                style: TextStyle(
                  color: AymaColors.fgMute,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AymaButton(
            label: _step < 4 ? 'Continue' : 'Get started',
            loading: _saving,
            onPressed: _canProceed ? _next : null,
          ),
          if (_step == 4) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _saving ? null : _save,
              child: Text(
                'Add photos later',
                style: TextStyle(color: AymaColors.fgMute, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showHowItWorks() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AymaColors.bgElev,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How Ayma works', style: AymaFonts.serif(size: 22)),
            const SizedBox(height: 16),
            _HowItem(
              icon: Icons.mic_rounded,
              title: 'Talk, don\'t fill forms',
              body:
                  'Ayma learns who you are through conversation — not surveys.',
            ),
            const SizedBox(height: 12),
            _HowItem(
              icon: Icons.favorite_border_rounded,
              title: 'Real introductions',
              body:
                  'When Ayma finds someone worth meeting, she\'ll make the intro personally.',
            ),
            const SizedBox(height: 12),
            _HowItem(
              icon: Icons.lock_outline_rounded,
              title: 'Private by design',
              body:
                  'What you share stays between you and Ayma unless you choose otherwise.',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step 0: Welcome ───────────────────────────────────────────────────────────

class _WelcomeStep extends StatelessWidget {
  final VoidCallback onHowItWorks;
  const _WelcomeStep({required this.onHowItWorks});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          const SizedBox(height: 20),
          const _BreathingOrb(size: 180),
          const SizedBox(height: 32),
          Text(
            'FIRST MEETING',
            style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text.rich(
              TextSpan(
                style: AymaFonts.serif(size: 34),
                children: [
                  const TextSpan(text: "Hi. I'm "),
                  TextSpan(
                    text: 'Ayma.',
                    style: AymaFonts.serif(
                      size: 34,
                      italic: true,
                      color: AymaColors.accent,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Text(
              "I'm your matchmaker. I'll get to know you through conversations — the same way a good friend might — then introduce you to people I think you'd actually like.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AymaColors.fgDim,
                fontSize: 15,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// ── Step 1: Community Selection ───────────────────────────────────────────────

class _CommunityStep extends StatelessWidget {
  final CommunityProfile? selected;
  final ValueChanged<CommunityProfile> onSelect;

  const _CommunityStep({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          _StepLabel('01 · YOUR CONTEXT'),
          const SizedBox(height: 16),
          Text('What are you looking for?', style: AymaFonts.serif(size: 28)),
          const SizedBox(height: 6),
          Text(
            'Choose the matchmaking context that fits your world.',
            style: TextStyle(color: AymaColors.fgDim, fontSize: 14),
          ),
          const SizedBox(height: 28),
          ...CommunityProfiles.all.map(
            (community) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _CommunityCard(
                community: community,
                isSelected: selected?.id == community.id,
                onTap: () => onSelect(community),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _CommunityCard extends StatelessWidget {
  final CommunityProfile community;
  final bool isSelected;
  final VoidCallback onTap;

  const _CommunityCard({
    required this.community,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? AymaColors.accentFaint : AymaColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AymaColors.accent : AymaColors.lineSoft,
            width: isSelected ? 1.5 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? AymaColors.accentSoft : AymaColors.bgElev,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                community.emoji,
                style: const TextStyle(fontSize: 22),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    community.displayName,
                    style: TextStyle(
                      color: isSelected ? AymaColors.accent : AymaColors.fg,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    community.shortDescription,
                    style: TextStyle(
                      color: AymaColors.fgDim,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AnimatedOpacity(
              opacity: isSelected ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AymaColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  color: AymaColors.bg,
                  size: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step 2: About You ─────────────────────────────────────────────────────────

class _AboutYouStep extends StatelessWidget {
  final TextEditingController nameCtrl;
  final String? gender;
  final int age;
  final VoidCallback onChanged;
  final ValueChanged<String> onGenderSelect;
  final ValueChanged<int> onAgeChanged;

  const _AboutYouStep({
    required this.nameCtrl,
    required this.gender,
    required this.age,
    required this.onChanged,
    required this.onGenderSelect,
    required this.onAgeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          _StepLabel('02 · ABOUT YOU'),
          const SizedBox(height: 16),
          Text("Let's start with the facts.", style: AymaFonts.serif(size: 28)),
          const SizedBox(height: 6),
          Text(
            "Three things. The rest I'll learn by talking to you.",
            style: TextStyle(color: AymaColors.fgDim, fontSize: 14),
          ),
          const SizedBox(height: 36),
          _SectionLabel('YOUR NAME'),
          const SizedBox(height: 8),
          _UnderlineField(
            controller: nameCtrl,
            hint: 'Enter your name',
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 32),
          _SectionLabel('YOU ARE'),
          const SizedBox(height: 12),
          _GenderGrid(selected: gender, onSelect: onGenderSelect),
          const SizedBox(height: 32),
          _SectionLabel('YOUR AGE'),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('$age', style: AymaFonts.serif(size: 48)),
              const SizedBox(width: 8),
              Text(
                'YEARS',
                style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: AymaColors.accent,
              inactiveTrackColor: AymaColors.lineSoft,
              thumbColor: AymaColors.accent,
              overlayColor: AymaColors.accentSoft,
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: Slider(
              value: age.toDouble(),
              min: 18,
              max: 70,
              divisions: 52,
              onChanged: (v) => onAgeChanged(v.round()),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Step 3: Preferences ──────────────────────────────────────────────────────

class _PreferencesStep extends StatelessWidget {
  final String? interestedIn;
  final int minAge, maxAge;
  final String locationText;
  final TextEditingController locationCtrl;
  final bool locationLoading, locationExpanded;
  final List<String> suggestions;
  final ValueChanged<String> onInterestSelect;
  final void Function(int, int) onRangeChange;
  final VoidCallback onLocationTap;
  final ValueChanged<String> onLocationChanged;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onDetect;
  final String? countryCode;

  const _PreferencesStep({
    required this.interestedIn,
    required this.minAge,
    required this.maxAge,
    required this.locationText,
    required this.locationCtrl,
    required this.locationLoading,
    required this.locationExpanded,
    required this.suggestions,
    required this.onInterestSelect,
    required this.onRangeChange,
    required this.onLocationTap,
    required this.onLocationChanged,
    required this.onSuggestionTap,
    required this.onDetect,
    required this.countryCode,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          _StepLabel('03 · WHO I SHOULD LOOK FOR'),
          const SizedBox(height: 16),
          Text('Just a starting point.', style: AymaFonts.serif(size: 28)),
          const SizedBox(height: 6),
          Text(
            "I'll refine this as we talk.",
            style: TextStyle(color: AymaColors.fgDim, fontSize: 14),
          ),
          const SizedBox(height: 36),
          _SectionLabel("I'M LOOKING FOR"),
          const SizedBox(height: 12),
          Row(
            children: ['Men', 'Women', 'Everyone'].map((g) {
              final sel = interestedIn == g.toLowerCase();
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Chip(
                    label: g,
                    selected: sel,
                    onTap: () => onInterestSelect(g.toLowerCase()),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
          _SectionLabel('AGE RANGE'),
          const SizedBox(height: 8),
          Text(
            '$minAge\u2009\u2014\u2009$maxAge',
            style: AymaFonts.serif(size: 40),
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: AymaColors.accent,
              inactiveTrackColor: AymaColors.lineSoft,
              thumbColor: AymaColors.accent,
              overlayColor: AymaColors.accentSoft,
              rangeThumbShape:
                  const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
              trackHeight: 2,
            ),
            child: RangeSlider(
              values: RangeValues(minAge.toDouble(), maxAge.toDouble()),
              min: 18,
              max: 70,
              divisions: 52,
              onChanged: (v) {
                final lo = v.start.round();
                final hi = v.end.round();
                if (lo < hi) onRangeChange(lo, hi);
              },
            ),
          ),
          const SizedBox(height: 32),
          _SectionLabel('NEAR'),
          const SizedBox(height: 10),
          _LocationCard(
            locationText: locationText,
            locationCtrl: locationCtrl,
            locationLoading: locationLoading,
            expanded: locationExpanded,
            suggestions: suggestions,
            onTap: onLocationTap,
            onChanged: onLocationChanged,
            onSuggestionTap: onSuggestionTap,
            onDetect: onDetect,
            countryCode: countryCode,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Micro-widgets ─────────────────────────────────────────────────────────────

class _StepLabel extends StatelessWidget {
  final String text;
  const _StepLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
      );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
      );
}

class _UnderlineField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  const _UnderlineField({
    required this.controller,
    required this.hint,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        onChanged: onChanged,
        style: AymaFonts.serif(size: 28),
        cursorColor: AymaColors.accent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AymaFonts.serif(size: 28, color: AymaColors.fgMute),
          border: const UnderlineInputBorder(
            borderSide: BorderSide(color: AymaColors.lineSoft, width: 0.5),
          ),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: AymaColors.lineSoft, width: 0.5),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: AymaColors.accent, width: 1),
          ),
          filled: false,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          isDense: true,
        ),
      );
}

class _GenderGrid extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;
  static const _options = ['Woman', 'Man', 'Non-binary', 'Other'];

  const _GenderGrid({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [0, 1].map((i) {
            final g = _options[i];
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 0 ? 8 : 0),
                child: _Chip(
                  label: g,
                  selected: selected == g.toLowerCase(),
                  onTap: () => onSelect(g.toLowerCase()),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [2, 3].map((i) {
            final g = _options[i];
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 2 ? 8 : 0),
                child: _Chip(
                  label: g,
                  selected: selected == g.toLowerCase(),
                  onTap: () => onSelect(g.toLowerCase()),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AymaColors.fg : Colors.transparent,
            borderRadius: BorderRadius.circular(50),
            border: Border.all(
              color: selected ? AymaColors.fg : AymaColors.line,
              width: selected ? 0 : 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AymaColors.bg : AymaColors.fg,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              letterSpacing: -0.1,
            ),
          ),
        ),
      );
}

class _LocationCard extends StatelessWidget {
  final String locationText;
  final TextEditingController locationCtrl;
  final bool locationLoading;
  final bool expanded;
  final List<String> suggestions;
  final VoidCallback onTap;
  final VoidCallback onDetect;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSuggestionTap;
  final String? countryCode;

  const _LocationCard({
    required this.locationText,
    required this.locationCtrl,
    required this.locationLoading,
    required this.expanded,
    required this.suggestions,
    required this.onTap,
    required this.onChanged,
    required this.onSuggestionTap,
    required this.onDetect,
    required this.countryCode,
  });

  @override
  Widget build(BuildContext context) {
    final unit = DistanceUnits.shortUnit(
      locationRegion: locationText,
      countryCode: countryCode,
    );
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AymaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AymaColors.lineSoft, width: 0.5),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.location_on_outlined,
                  color: AymaColors.fgMute,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: expanded
                      ? TextField(
                          controller: locationCtrl,
                          autofocus: true,
                          style: TextStyle(color: AymaColors.fg, fontSize: 15),
                          decoration: InputDecoration(
                            hintText: 'City or region',
                            hintStyle: TextStyle(
                              color: AymaColors.fgMute,
                              fontSize: 15,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: onChanged,
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              locationText.isEmpty
                                  ? 'Set your location'
                                  : locationText,
                              style: TextStyle(
                                color: locationText.isEmpty
                                    ? AymaColors.fgMute
                                    : AymaColors.fg,
                                fontSize: 15,
                              ),
                            ),
                            if (locationText.isNotEmpty)
                              Text(
                                'Within 25 $unit',
                                style: TextStyle(
                                  color: AymaColors.fgMute,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                ),
                if (locationLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (expanded)
                  GestureDetector(
                    onTap: onDetect,
                    child: Icon(
                      Icons.my_location_rounded,
                      color: AymaColors.accent,
                      size: 18,
                    ),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: AymaColors.fgMute,
                    size: 18,
                  ),
              ],
            ),
          ),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: AymaColors.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AymaColors.lineSoft, width: 0.5),
            ),
            child: Column(
              children: suggestions
                  .map(
                    (s) => ListTile(
                      dense: true,
                      title: Text(
                        s,
                        style: TextStyle(color: AymaColors.fg, fontSize: 14),
                      ),
                      onTap: () => onSuggestionTap(s),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Step 4: Photos ────────────────────────────────────────────────────────────

class _PhotoStep extends StatelessWidget {
  final List<String> photoUrls;
  final bool uploading;
  final VoidCallback onAdd;
  final ValueChanged<int> onSetPrimary;
  final ValueChanged<int> onDelete;

  const _PhotoStep({
    required this.photoUrls,
    required this.uploading,
    required this.onAdd,
    required this.onSetPrimary,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          _StepLabel('04 · YOUR PHOTOS'),
          const SizedBox(height: 16),
          Text('Show your face.', style: AymaFonts.serif(size: 28)),
          const SizedBox(height: 6),
          Text(
            'Tap to set as main photo. Ayma will use these to learn how to describe you.',
            style: TextStyle(color: AymaColors.fgDim, fontSize: 14),
          ),
          const SizedBox(height: 32),
          if (photoUrls.isNotEmpty) ...[
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: photoUrls.length,
              itemBuilder: (_, i) {
                final isPrimary = i == 0;
                return GestureDetector(
                  onTap: isPrimary ? null : () => onSetPrimary(i),
                  onLongPress: () => onDelete(i),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          photoUrls[i],
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: AymaColors.bgCard,
                            child: Icon(Icons.broken_image_outlined,
                                color: AymaColors.fgMute),
                          ),
                        ),
                      ),
                      if (isPrimary)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AymaColors.accent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'MAIN',
                              style: AymaFonts.mono(
                                  size: 8, color: AymaColors.bg),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => onDelete(i),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close,
                                size: 13, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
          ],
          GestureDetector(
            onTap: uploading ? null : onAdd,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                color: AymaColors.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AymaColors.lineSoft, width: 0.5),
              ),
              child: uploading
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_photo_alternate_outlined,
                            color: AymaColors.fgMute, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          photoUrls.isEmpty
                              ? 'Add photos'
                              : 'Add more photos',
                          style:
                              TextStyle(color: AymaColors.fgDim, fontSize: 15),
                        ),
                      ],
                    ),
            ),
          ),
          if (photoUrls.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Long-press a photo to delete it',
                style: TextStyle(color: AymaColors.fgMute, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _LargeButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _LargeButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onPressed,
        child: Container(
          width: double.infinity,
          height: 58,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AymaColors.fg,
            borderRadius: BorderRadius.circular(50),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: AymaColors.bg,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.2,
            ),
          ),
        ),
      );
}

class _HowItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _HowItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AymaColors.accentFaint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AymaColors.accent, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AymaColors.fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    color: AymaColors.fgDim,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}
