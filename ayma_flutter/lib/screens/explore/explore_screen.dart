import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/firestore_service.dart';
import '../../theme.dart';
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
    final filters  = ref.watch(exploreFiltersProvider);
    final resultAsync = ref.watch(exploreProvider);

    return Scaffold(
      backgroundColor: AymaColors.bg,
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
                    style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
                  ).animate().fadeIn(duration: 300.ms),
                  const SizedBox(height: 6),
                  Text(
                    'Browse profiles',
                    style: AymaFonts.serif(size: 32, color: AymaColors.fg),
                  ).animate(delay: 60.ms).fadeIn(duration: 400.ms),
                  const SizedBox(height: 16),

                  // Search bar
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AymaColors.bgElev,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.search_rounded, size: 18, color: AymaColors.fgMute),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: _onSearch,
                            style: const TextStyle(color: AymaColors.fg, fontSize: 14),
                            cursorColor: AymaColors.accent,
                            decoration: const InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: 'Search by name, interest…',
                              hintStyle: TextStyle(color: AymaColors.fgMute, fontSize: 14),
                            ),
                          ),
                        ),
                        if (filters.query.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _searchCtrl.clear();
                              _setFilter((f) => f.copyWith(query: ''));
                            },
                            child: const Icon(Icons.close_rounded, size: 16, color: AymaColors.fgMute),
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
                          onTap: () => _setFilter((f) => f.copyWith(gender: null)),
                        ),
                        const SizedBox(width: 8),
                        _FilterChip(
                          label: 'Women',
                          active: filters.gender == 'women',
                          onTap: () => _setFilter((f) => f.copyWith(
                              gender: filters.gender == 'women' ? null : 'women')),
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
                          onChanged: (min, max) =>
                              _setFilter((f) => f.copyWith(ageMin: min, ageMax: max)),
                        ),
                        const SizedBox(width: 8),
                        _RadiusFilterChip(
                          radiusKm: filters.radiusKm,
                          onChanged: (r) => _setFilter((f) => f.copyWith(radiusKm: r)),
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
                        onTap: () => _setFilter((f) => f.copyWith(tab: 'people')),
                      ),
                      const SizedBox(width: 8),
                      _TabPill(
                        label: 'Prompts',
                        active: filters.tab == 'prompts',
                        onTap: () => _setFilter((f) => f.copyWith(tab: 'prompts')),
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
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AymaColors.accent,
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
                        : _PeopleGrid(people: people.cast<Map<String, dynamic>>());
                  } else {
                    final prompts = (data['prompts'] as List?) ?? [];
                    return prompts.isEmpty
                        ? _EmptyState(tab: 'prompts')
                        : _PromptsList(prompts: prompts.cast<Map<String, dynamic>>());
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

  const _FilterChip({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AymaColors.accent.withValues(alpha: 0.14) : AymaColors.bgElev,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: active ? AymaColors.accent.withValues(alpha: 0.4) : AymaColors.lineSoft,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? AymaColors.accent : AymaColors.fgDim,
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

  const _AgeFilterChip({required this.ageMin, required this.ageMax, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDefault = ageMin == 18 && ageMax == 60;
    return GestureDetector(
      onTap: () => _showAgeSheet(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: !isDefault ? AymaColors.accent.withValues(alpha: 0.14) : AymaColors.bgElev,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: !isDefault ? AymaColors.accent.withValues(alpha: 0.4) : AymaColors.lineSoft,
            width: 0.5,
          ),
        ),
        child: Text(
          '$ageMin–$ageMax yrs',
          style: TextStyle(
            fontSize: 12,
            color: !isDefault ? AymaColors.accent : AymaColors.fgDim,
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
                  style: AymaFonts.serif(size: 28, color: AymaColors.fg)),
              const SizedBox(height: 12),
              RangeSlider(
                values: RangeValues(min.toDouble(), max.toDouble()),
                min: 18, max: 70,
                divisions: 52,
                activeColor: AymaColors.accent,
                inactiveColor: AymaColors.lineSoft,
                onChanged: (v) {
                  final lo = v.start.round();
                  final hi = v.end.round();
                  if (lo < hi) setS(() { min = lo; max = hi; });
                },
              ),
              const SizedBox(height: 16),
              _ApplyBtn(onTap: () { Navigator.pop(ctx); onChanged(min, max); }),
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

  const _RadiusFilterChip({required this.radiusKm, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDefault = radiusKm == 50;
    return GestureDetector(
      onTap: () => _showRadiusSheet(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: !isDefault ? AymaColors.accent.withValues(alpha: 0.14) : AymaColors.bgElev,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: !isDefault ? AymaColors.accent.withValues(alpha: 0.4) : AymaColors.lineSoft,
            width: 0.5,
          ),
        ),
        child: Text(
          '$radiusKm km',
          style: TextStyle(
            fontSize: 12,
            color: !isDefault ? AymaColors.accent : AymaColors.fgDim,
          ),
        ),
      ),
    );
  }

  void _showRadiusSheet(BuildContext context) {
    int r = radiusKm;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => _FilterSheet(
          title: 'Distance',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$r km',
                  style: AymaFonts.serif(size: 28, color: AymaColors.fg)),
              const SizedBox(height: 12),
              Slider(
                value: r.toDouble(),
                min: 5, max: 200,
                divisions: 39,
                activeColor: AymaColors.accent,
                inactiveColor: AymaColors.lineSoft,
                onChanged: (v) => setS(() => r = v.round()),
              ),
              const SizedBox(height: 16),
              _ApplyBtn(onTap: () { Navigator.pop(ctx); onChanged(r); }),
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
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: AymaFonts.mono(size: 10, color: AymaColors.fgMute)),
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
          color: AymaColors.fg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Text('Apply', style: TextStyle(fontSize: 14,
              fontWeight: FontWeight.w500, color: Colors.black)),
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

  const _TabPill({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: active ? AymaColors.fg : Colors.transparent,
          borderRadius: BorderRadius.circular(99),
          border: active ? null : Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: active ? Colors.black : AymaColors.fgDim,
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
        return _ProfileCard(
          profile: p,
          name: (p['display_name'] as String?) ?? 'Someone',
          age:  p['age'] as int?,
          job:  (p['job'] as String?) ?? '',
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
  final String job;
  final int seed;
  final int delay;

  const _ProfileCard({
    required this.profile,
    required this.name,
    required this.age,
    required this.job,
    required this.seed,
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
        color: AymaColors.bgElev,
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
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
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: AymaFonts.serif(size: 18, color: AymaColors.fg)),
                    ),
                    if (age != null) ...[
                      const SizedBox(width: 5),
                      Text('· $age',
                          style: const TextStyle(fontSize: 12, color: AymaColors.fgMute)),
                    ],
                  ],
                ),
                if (job.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(job, style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
                ],
              ],
            ),
          ),
        ],
      ),
    )).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 300.ms).slideY(begin: 0.04, end: 0);
  }
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
            color: AymaColors.bgElev,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
          ),
          child: Text(
            text,
            style: AymaFonts.serif(size: 18, italic: true, color: AymaColors.fg),
          ),
        ).animate(delay: Duration(milliseconds: i * 50)).fadeIn(duration: 300.ms).slideY(begin: 0.04, end: 0);
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
              tab == 'people' ? Icons.people_outline_rounded : Icons.chat_bubble_outline_rounded,
              size: 40,
              color: AymaColors.fgMute,
            ),
            const SizedBox(height: 16),
            Text(
              tab == 'people'
                  ? 'No profiles match your filters'
                  : 'No prompts available yet',
              style: AymaFonts.serif(size: 20, color: AymaColors.fgDim),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              tab == 'people'
                  ? 'Try widening your age range or distance.'
                  : 'Check back after your next conversation.',
              style: const TextStyle(color: AymaColors.fgMute, fontSize: 13, height: 1.5),
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
              style: TextStyle(color: AymaColors.fgDim, fontSize: 14)),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: AymaColors.bgElev,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AymaColors.lineSoft, width: 0.5),
              ),
              child: const Text('Retry',
                  style: TextStyle(color: AymaColors.fg, fontSize: 13)),
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
        : FirestoreService.getPublicProfile(id);
  }

  Future<void> _generateScore(String userId) async {
    setState(() => _busy = true);
    try {
      final score = await FirestoreService.generateMatchScore(userId);
      if (!mounted) return;
      setState(() => _matchScore = score);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendPoke(String userId) async {
    setState(() => _busy = true);
    try {
      await FirestoreService.sendPoke(userId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Poke sent')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendMessage(String userId) async {
    final p = await _profileFuture;
    final name = ((p?['display_name'] as String?) ?? 'Message').trim();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DirectMessageScreen(
          targetUserId: userId,
          targetName: name.isEmpty ? 'Message' : name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AymaColors.bg,
      appBar: AppBar(
        backgroundColor: AymaColors.bg,
        foregroundColor: AymaColors.fg,
        elevation: 0,
        title: const Text('Profile'),
      ),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _profileFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AymaColors.accent),
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
          final photos = (p['photos'] as List?)?.cast<String>() ?? const <String>[];

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              if (photos.isNotEmpty) ...[
                SizedBox(
                  height: 220,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        photos[i],
                        width: 170,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 170,
                          color: AymaColors.bgElev,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AymaColors.bgElev,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name?.isNotEmpty == true ? name! : 'Someone',
                      style: AymaFonts.serif(size: 30, color: AymaColors.fg),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        if (age is int) '$age',
                        if (gender != null && gender.isNotEmpty) gender,
                        if (interestedIn != null && interestedIn.isNotEmpty)
                          'Interested in $interestedIn',
                        if (location != null && location.isNotEmpty) location,
                      ].join(' · '),
                      style: const TextStyle(color: AymaColors.fgMute, fontSize: 14),
                    ),
                    if (bio != null && bio.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        bio,
                        style: AymaFonts.elegantSans(size: 15, color: AymaColors.fg)
                            .copyWith(height: 1.6),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _ActionBtn(
                          label: _matchScore == null
                              ? 'Generate Match Score'
                              : 'Match ${(100 * _matchScore!).round()}%',
                          onTap: _busy || userId.isEmpty
                              ? null
                              : () => _generateScore(userId),
                        ),
                        _ActionBtn(
                          label: 'Send Poke',
                          onTap: _busy || userId.isEmpty
                              ? null
                              : () => _sendPoke(userId),
                        ),
                        _ActionBtn(
                          label: 'Message',
                          onTap: _busy || userId.isEmpty
                              ? null
                              : () => _sendMessage(userId),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _ActionBtn({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AymaColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: onTap == null ? AymaColors.fgMute : AymaColors.fg,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
