import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/api_service.dart';
import '../../theme.dart';
import '../../utils/distance_units.dart';
import '../../widgets/public_profile_view.dart';
import 'direct_message_screen.dart';

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _setFilter(ExploreFilters Function(ExploreFilters) updater) {
    final current = ref.read(exploreFiltersProvider);
    ref.read(exploreFiltersProvider.notifier).state = updater(current);
  }

  void _onSearch(String val) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _setFilter((f) => f.copyWith(query: val));
    });
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(exploreFiltersProvider);
    final myProfile = ref.watch(profileProvider).value;
    final countryCode = DistanceUnits.countryCodeFromContext(context);
    final locationRegion = myProfile?.locationRegion;
    final resultAsync = ref.watch(exploreProvider);

    return Scaffold(
      backgroundColor: context.ac.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'EXPLORE',
                    style: AymaFonts.mono(size: 10, color: context.ac.fgMute),
                  ).animate().fadeIn(duration: 300.ms),
                  const SizedBox(height: 6),
                  Text(
                    'Browse profiles',
                    style: AymaFonts.serif(size: 32, color: context.ac.fg),
                  ).animate(delay: 60.ms).fadeIn(duration: 400.ms),
                  const SizedBox(height: 16),

                  // Search bar
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: context.ac.bgElev,
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: context.ac.lineSoft, width: 0.5),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search_rounded,
                            size: 18, color: context.ac.fgMute),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: _onSearch,
                            style: TextStyle(
                                color: context.ac.fg, fontSize: 14),
                            cursorColor: context.ac.accent,
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: 'Search by name, interest…',
                              hintStyle: TextStyle(
                                  color: context.ac.fgMute, fontSize: 14),
                            ),
                          ),
                        ),
                        if (filters.query.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _searchCtrl.clear();
                              _setFilter((f) => f.copyWith(query: ''));
                            },
                            child: Icon(Icons.close_rounded,
                                size: 16, color: context.ac.fgMute),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Filter chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _FilterChip(
                          label: 'Everyone',
                          active: filters.gender == null,
                          onTap: () =>
                              _setFilter((f) => f.copyWith(gender: null)),
                        ),
                        const SizedBox(width: 8),
                        _FilterChip(
                          label: 'Women',
                          active: filters.gender == 'women',
                          onTap: () => _setFilter((f) => f.copyWith(
                              gender:
                                  filters.gender == 'women' ? null : 'women')),
                        ),
                        const SizedBox(width: 8),
                        _FilterChip(
                          label: 'Men',
                          active: filters.gender == 'men',
                          onTap: () => _setFilter((f) => f.copyWith(
                              gender: filters.gender == 'men' ? null : 'men')),
                        ),
                        const SizedBox(width: 8),
                        _AgeFilterChip(
                          ageMin: filters.ageMin,
                          ageMax: filters.ageMax,
                          onChanged: (min, max) => _setFilter(
                              (f) => f.copyWith(ageMin: min, ageMax: max)),
                        ),
                        const SizedBox(width: 8),
                        _RadiusFilterChip(
                          radiusKm: filters.radiusKm,
                          onChanged: (r) =>
                              _setFilter((f) => f.copyWith(radiusKm: r)),
                          countryCode: countryCode,
                          locationRegion: locationRegion,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Tab switcher
                  Row(
                    children: [
                      _TabPill(
                        label: 'People',
                        active: filters.tab == 'people',
                        onTap: () =>
                            _setFilter((f) => f.copyWith(tab: 'people')),
                      ),
                      const SizedBox(width: 8),
                      _TabPill(
                        label: 'Prompts',
                        active: filters.tab == 'prompts',
                        onTap: () =>
                            _setFilter((f) => f.copyWith(tab: 'prompts')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Results ─────────────────────────────────────────────
            Expanded(
              child: resultAsync.when(
                loading: () => Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: context.ac.accent,
                  ),
                ),
                error: (e, _) => _ErrorState(
                  onRetry: () => ref.invalidate(exploreProvider),
                ),
                data: (data) {
                  if (filters.tab == 'people') {
                    final people = (data['people'] as List?) ?? [];
                    return people.isEmpty
                        ? _EmptyState(tab: 'people')
                        : _PeopleGrid(
                            people: people.cast<Map<String, dynamic>>());
                  } else {
                    final prompts = (data['prompts'] as List?) ?? [];
                    return prompts.isEmpty
                        ? _EmptyState(tab: 'prompts')
                        : _PromptsList(
                            prompts: prompts.cast<Map<String, dynamic>>());
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Filter chips ──────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterChip(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? context.ac.accent.withValues(alpha: 0.14)
              : context.ac.bgElev,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: active
                ? context.ac.accent.withValues(alpha: 0.4)
                : context.ac.lineSoft,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? context.ac.accent : context.ac.fgDim,
            fontWeight: active ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _AgeFilterChip extends StatelessWidget {
  final int ageMin, ageMax;
  final void Function(int, int) onChanged;

  const _AgeFilterChip(
      {required this.ageMin, required this.ageMax, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDefault = ageMin == 0 && ageMax == 120;
    return GestureDetector(
      onTap: () => _showAgeSheet(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: !isDefault
              ? context.ac.accent.withValues(alpha: 0.14)
              : context.ac.bgElev,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: !isDefault
                ? context.ac.accent.withValues(alpha: 0.4)
                : context.ac.lineSoft,
            width: 0.5,
          ),
        ),
        child: Text(
          isDefault ? 'Any age' : '$ageMin–$ageMax yrs',
          style: TextStyle(
            fontSize: 12,
            color: !isDefault ? context.ac.accent : context.ac.fgDim,
          ),
        ),
      ),
    );
  }

  void _showAgeSheet(BuildContext context) {
    int min = ageMin, max = ageMax;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => _FilterSheet(
          title: 'Age range',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$min – $max',
                  style: AymaFonts.serif(size: 28, color: ctx.ac.fg)),
              const SizedBox(height: 12),
              RangeSlider(
                values: RangeValues(min.toDouble(), max.toDouble()),
                min: 0,
                max: 120,
                divisions: 120,
                activeColor: ctx.ac.accent,
                inactiveColor: ctx.ac.lineSoft,
                onChanged: (v) {
                  final lo = v.start.round();
                  final hi = v.end.round();
                  if (lo < hi) {
                    setS(() {
                      min = lo;
                      max = hi;
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              _ApplyBtn(onTap: () {
                Navigator.pop(ctx);
                onChanged(min, max);
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _RadiusFilterChip extends StatelessWidget {
  final int radiusKm;
  final ValueChanged<int> onChanged;
  final String? countryCode;
  final String? locationRegion;

  const _RadiusFilterChip({
    required this.radiusKm,
    required this.onChanged,
    required this.countryCode,
    required this.locationRegion,
  });

  @override
  Widget build(BuildContext context) {
    final isDefault = radiusKm == 50;
    final formatted = DistanceUnits.formatFromKm(
      radiusKm,
      countryCode: countryCode,
      locationRegion: locationRegion,
    );
    return GestureDetector(
      onTap: () => _showRadiusSheet(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: !isDefault
              ? context.ac.accent.withValues(alpha: 0.14)
              : context.ac.bgElev,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: !isDefault
                ? context.ac.accent.withValues(alpha: 0.4)
                : context.ac.lineSoft,
            width: 0.5,
          ),
        ),
        child: Text(
          formatted,
          style: TextStyle(
            fontSize: 12,
            color: !isDefault ? context.ac.accent : context.ac.fgDim,
          ),
        ),
      ),
    );
  }

  void _showRadiusSheet(BuildContext context) {
    const minKm = 5;
    const maxKm = 200;
    final displayMin = DistanceUnits.fromKm(
      minKm,
      countryCode: countryCode,
      locationRegion: locationRegion,
    );
    final displayMax = DistanceUnits.fromKm(
      maxKm,
      countryCode: countryCode,
      locationRegion: locationRegion,
    );
    final unit = DistanceUnits.shortUnit(
      countryCode: countryCode,
      locationRegion: locationRegion,
    );
    int displayRadius = DistanceUnits.fromKm(
      radiusKm,
      countryCode: countryCode,
      locationRegion: locationRegion,
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => _FilterSheet(
          title: 'Distance',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$displayRadius $unit',
                  style: AymaFonts.serif(size: 28, color: ctx.ac.fg)),
              const SizedBox(height: 12),
              Slider(
                value: displayRadius.toDouble(),
                min: displayMin.toDouble(),
                max: displayMax.toDouble(),
                divisions: (displayMax - displayMin).clamp(1, 500),
                activeColor: ctx.ac.accent,
                inactiveColor: ctx.ac.lineSoft,
                onChanged: (v) => setS(() => displayRadius = v.round()),
              ),
              const SizedBox(height: 16),
              _ApplyBtn(onTap: () {
                Navigator.pop(ctx);
                onChanged(
                  DistanceUnits.toKm(
                    displayRadius,
                    countryCode: countryCode,
                    locationRegion: locationRegion,
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterSheet extends StatelessWidget {
  final String title;
  final Widget child;
  const _FilterSheet({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      decoration: BoxDecoration(
        color: context.ac.bgElev,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: context.ac.lineSoft, width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: AymaFonts.mono(size: 10, color: context.ac.fgMute)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _ApplyBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _ApplyBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: context.ac.fg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Text('Apply',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black)),
        ),
      ),
    );
  }
}

// ── Tab pill ──────────────────────────────────────────────────────────────────

class _TabPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TabPill(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: active ? context.ac.fg : Colors.transparent,
          borderRadius: BorderRadius.circular(99),
          border: active
              ? null
              : Border.all(color: context.ac.lineSoft, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: active ? Colors.black : context.ac.fgDim,
            fontWeight: active ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// ── People grid ───────────────────────────────────────────────────────────────

class _PeopleGrid extends StatelessWidget {
  final List<Map<String, dynamic>> people;
  const _PeopleGrid({required this.people});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: people.length,
      itemBuilder: (_, i) {
        final p = people[i];
        final rawLoc = (p['location_region'] as String?) ?? '';
        final city = rawLoc.isNotEmpty ? rawLoc.split(',').first.trim() : '';
        final photos = (p['photo_order'] as List?)?.whereType<String>().toList() ?? [];
        return _ProfileCard(
          profile: p,
          name: (p['display_name'] as String?) ?? 'Someone',
          age: p['age'] as int?,
          photoUrl: photos.isNotEmpty ? photos.first : null,
          location: city,
          isOnline: (p['is_online'] as bool?) ?? false,
          seed: p['id'].hashCode.abs() % 30 + 1,
          delay: i * 40,
        );
      },
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final Map<String, dynamic> profile;
  final String name;
  final int? age;
  final String? photoUrl;
  final String location;
  final bool isOnline;
  final int seed;
  final int delay;

  const _ProfileCard({
    required this.profile,
    required this.name,
    required this.age,
    required this.seed,
    this.photoUrl,
    this.location = '',
    this.isOnline = false,
    this.delay = 0,
  });

  @override
  Widget build(BuildContext context) {
    final h1 = (seed * 37) % 360;
    final h2 = (h1 + 40) % 360;

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _ExploreProfileScreen(profile: profile),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: context.ac.bgCard,
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Photo or gradient placeholder
            if (photoUrl != null && photoUrl!.isNotEmpty)
              Image.network(
                photoUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _CardPlaceholder(h1: h1, h2: h2),
              )
            else
              _CardPlaceholder(h1: h1, h2: h2),
            // Bottom gradient scrim
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: Container(
                height: 110,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xCC000000)],
                  ),
                ),
              ),
            ),
            // Name / age / location / online
            Positioned(
              left: 12, right: 12, bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          style: AymaFonts.serif(size: 20, color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (age != null) ...[
                        const SizedBox(width: 5),
                        Text(
                          '· \$age',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 15),
                        ),
                      ],
                    ],
                  ),
                  if (location.isNotEmpty || isOnline) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (isOnline) ...[
                          Container(
                            width: 6, height: 6,
                            decoration: const BoxDecoration(
                              color: Color(0xFF46D96A),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        if (location.isNotEmpty)
                          Flexible(
                            child: Text(
                              location,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    )
        .animate(delay: Duration(milliseconds: delay))
        .fadeIn(duration: 300.ms)
        .slideY(begin: 0.04, end: 0);
  }
}

class _CardPlaceholder extends StatelessWidget {
  final int h1, h2;
  const _CardPlaceholder({required this.h1, required this.h2});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [
          HSLColor.fromAHSL(1, h1.toDouble(), 0.3, 0.25).toColor(),
          HSLColor.fromAHSL(1, h2.toDouble(), 0.25, 0.18).toColor(),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Icon(Icons.person_outline_rounded,
          size: 40, color: Colors.white.withValues(alpha: 0.15)),
    ),
  );
}

// ── Prompts list ──────────────────────────────────────────────────────────────

class _PromptsList extends StatelessWidget {
  final List<Map<String, dynamic>> prompts;
  const _PromptsList({required this.prompts});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
      itemCount: prompts.length,
      itemBuilder: (_, i) {
        final text = (prompts[i]['text'] as String?) ?? '';
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: context.ac.bgElev,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: context.ac.lineSoft, width: 0.5),
          ),
          child: Text(
            text,
            style:
                AymaFonts.serif(size: 18, italic: true, color: context.ac.fg),
          ),
        )
            .animate(delay: Duration(milliseconds: i * 50))
            .fadeIn(duration: 300.ms)
            .slideY(begin: 0.04, end: 0);
      },
    );
  }
}

// ── Empty / Error ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String tab;
  const _EmptyState({required this.tab});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab == 'people'
                  ? Icons.people_outline_rounded
                  : Icons.chat_bubble_outline_rounded,
              size: 40,
              color: context.ac.fgMute,
            ),
            const SizedBox(height: 16),
            Text(
              tab == 'people'
                  ? 'No profiles match your filters'
                  : 'No prompts available yet',
              style: AymaFonts.serif(size: 20, color: context.ac.fgDim),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              tab == 'people'
                  ? 'Try widening your age range or distance.'
                  : 'Check back after your next conversation.',
              style: TextStyle(
                  color: context.ac.fgMute, fontSize: 13, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Could not load profiles',
              style: TextStyle(color: context.ac.fgDim, fontSize: 14)),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: context.ac.bgElev,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.ac.lineSoft, width: 0.5),
              ),
              child: Text('Retry',
                  style: TextStyle(color: context.ac.fg, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExploreProfileScreen extends StatefulWidget {
  final Map<String, dynamic> profile;
  const _ExploreProfileScreen({required this.profile});

  @override
  State<_ExploreProfileScreen> createState() => _ExploreProfileScreenState();
}

class _ExploreProfileScreenState extends State<_ExploreProfileScreen> {
  late Future<Map<String, dynamic>?> _profileFuture;
  double? _matchScore;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final id = widget.profile['id'] as String?;
    _profileFuture = id == null
        ? Future.value(widget.profile)
        : ApiService.getPublicProfile(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.ac.bg,
      appBar: AppBar(
        backgroundColor: context.ac.bg,
        foregroundColor: context.ac.fg,
        elevation: 0,
        title: const Text('Profile'),
      ),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _profileFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Center(
              child: CircularProgressIndicator(color: context.ac.accent),
            );
          }
          final p = (snap.data != null && snap.data!.isNotEmpty)
              ? snap.data!
              : widget.profile;
          final userId = p['id'] as String? ?? '';
          final name = (p['display_name'] as String?)?.trim();
          final age = p['age'];
          final gender = (p['gender'] as String?)?.trim();
          final interestedIn =
              ((p['matching_prefs'] as Map?)?['interested_in'] as String?)
                  ?.trim();
          final bio = (p['profile_public'] as String?)?.trim();
          final location = (p['location_region'] as String?)?.trim();
          final job = ((p['job'] as String?) ?? (p['occupation'] as String?) ?? '').trim();
          final company = ((p['company'] as String?) ?? (p['employer'] as String?) ?? '').trim();
          final jobPill = job.isNotEmpty ? (company.isNotEmpty ? '$job · $company' : job) : '';
          final extraPills = <String>[
            jobPill,
            ((p['height_text'] as String?) ?? (p['height'] as String?) ?? '').trim(),
            ((p['pronouns'] as String?) ?? '').trim(),
            ((p['religion'] as String?) ?? '').trim(),
            ((p['relationship_goal'] as String?) ?? '').trim(),
          ].where((e) => e.isNotEmpty).toList();
          final photos =
              (p['photos'] as List?)?.cast<String>() ?? const <String>[];

          return PublicProfileView(
            photos: photos,
            name: name?.isNotEmpty == true ? name! : 'Someone',
            age: age is int ? age : null,
            gender: gender ?? '',
            location: location ?? '',
            interestedIn: interestedIn ?? '',
            bio: bio ?? '',
            extraPills: extraPills,
            isOnline: true,
            showEditControls: false,
            bottom: _ProfileActions(
              userId: userId,
              profileFuture: _profileFuture,
              matchScore: _matchScore,
              onScoreGenerated: (s) => setState(() => _matchScore = s),
              busy: _busy,
              onBusyChanged: (b) => setState(() => _busy = b),
            ),
          );
        },
      ),
    );
  }
}

class _ProfileActions extends StatefulWidget {
  final String userId;
  final Future<Map<String, dynamic>?> profileFuture;
  final double? matchScore;
  final ValueChanged<double> onScoreGenerated;
  final bool busy;
  final ValueChanged<bool> onBusyChanged;

  const _ProfileActions({
    required this.userId,
    required this.profileFuture,
    required this.matchScore,
    required this.onScoreGenerated,
    required this.busy,
    required this.onBusyChanged,
  });

  @override
  State<_ProfileActions> createState() => _ProfileActionsState();
}

class _ProfileActionsState extends State<_ProfileActions> {
  bool _liked = false;

  Future<void> _like() async {
    if (_liked || widget.busy || widget.userId.isEmpty) return;
    widget.onBusyChanged(true);
    try {
      await ApiService.sendPoke(widget.userId);
      if (mounted) setState(() => _liked = true);
    } finally {
      widget.onBusyChanged(false);
    }
  }

  Future<void> _message() async {
    final p = await widget.profileFuture;
    final name = ((p?['display_name'] as String?) ?? 'Message').trim();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DirectMessageScreen(
        targetUserId: widget.userId,
        targetName: name.isEmpty ? 'Message' : name,
      ),
    ));
  }

  Future<void> _score() async {
    if (widget.busy || widget.userId.isEmpty) return;
    widget.onBusyChanged(true);
    try {
      final s = await ApiService.generateMatchScore(widget.userId);
      if (mounted) widget.onScoreGenerated(s);
    } finally {
      widget.onBusyChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _ActionBtn(
          label: _liked ? 'Liked' : 'Like Photos',
          icon: _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          accent: _liked,
          onTap: widget.busy || widget.userId.isEmpty ? null : _like,
        )),
        const SizedBox(width: 8),
        Expanded(child: _ActionBtn(
          label: 'Message',
          icon: Icons.chat_bubble_outline_rounded,
          onTap: widget.busy || widget.userId.isEmpty ? null : _message,
        )),
        const SizedBox(width: 8),
        Expanded(child: _ActionBtn(
          label: widget.matchScore == null
              ? 'Match'
              : '${(100 * widget.matchScore!).round()}%',
          icon: Icons.stars_rounded,
          onTap: widget.busy || widget.userId.isEmpty ? null : _score,
        )),
      ],
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool accent;
  const _ActionBtn({required this.label, this.onTap, this.icon, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = accent ? context.ac.accent : (enabled ? context.ac.fg : context.ac.fgMute);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(
          color: accent ? context.ac.accentFaint : context.ac.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accent ? context.ac.accentSoft : context.ac.lineSoft,
            width: 0.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 18, color: color),
            if (icon != null) const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
