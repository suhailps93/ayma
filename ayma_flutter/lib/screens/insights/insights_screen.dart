import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/backend_service.dart';
import '../../theme.dart';

// ── Insights screen ────────────────────────────────────────────────────────────
// Shows all four wiki pages that Ayma maintains about the user.
// Mobile: single-column cards. Tablet/wide: 2-column grid.

class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key});

  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await BackendService.post('/api/insights/refresh', {});
    } catch (_) {
      // Endpoint may not exist; fall through to invalidate anyway
    }
    ref.invalidate(insightsProvider);
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(insightsProvider);

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: async.when(
          loading: () => const _LoadingView(),
          error: (e, _) => _ErrorView(message: e.toString()),
          data: (data) => _InsightsView(data: data, onRefresh: _refresh, refreshing: _refreshing),
        ),
      ),
    );
  }
}

// ── Main view ─────────────────────────────────────────────────────────────────

class _InsightsView extends StatelessWidget {
  final Map<String, String> data;
  final VoidCallback onRefresh;
  final bool refreshing;
  const _InsightsView({required this.data, required this.onRefresh, required this.refreshing});

  static const _pages = [
    _PageDef(
      key: 'about_me',
      title: 'About You',
      subtitle: 'Who you are',
      icon: Icons.person_outline_rounded,
      emptyHint: 'Talk to Ayma and she\'ll start building a picture of who you are.',
    ),
    _PageDef(
      key: 'preferences',
      title: 'What You\'re Looking For',
      subtitle: 'Your ideal match',
      icon: Icons.favorite_border_rounded,
      emptyHint: 'Tell Ayma what you\'re looking for in a partner.',
    ),
    _PageDef(
      key: 'context',
      title: 'Right Now',
      subtitle: 'Your current chapter',
      icon: Icons.wb_sunny_outlined,
      emptyHint: 'Ayma will capture what\'s going on in your life right now.',
    ),
    _PageDef(
      key: 'media',
      title: 'Your Photos',
      subtitle: 'How Ayma sees your photos',
      icon: Icons.photo_library_outlined,
      emptyHint: 'Upload photos and Ayma will describe them for matching.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 600;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Header(onRefresh: onRefresh, refreshing: refreshing)),
        if (isWide)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _WikiCard(
                  def: _pages[i],
                  content: data[_pages[i].key] ?? '',
                  delay: Duration(milliseconds: 80 + i * 60),
                ),
                childCount: _pages.length,
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => Padding(
                  padding: EdgeInsets.only(bottom: i < _pages.length - 1 ? 16 : 0),
                  child: _WikiCard(
                    def: _pages[i],
                    content: data[_pages[i].key] ?? '',
                    delay: Duration(milliseconds: 80 + i * 70),
                  ),
                ),
                childCount: _pages.length,
              ),
            ),
          ),
      ],
    );
  }
}

// ── Header ─────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final VoidCallback onRefresh;
  final bool refreshing;
  const _Header({required this.onRefresh, required this.refreshing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'YOUR STORY',
                style: AymaFonts.serif(size: 36, color: AymaColors.fg),
              ).animate().fadeIn(duration: 400.ms),
              const Spacer(),
              // Refresh button
              GestureDetector(
                onTap: refreshing ? null : onRefresh,
                child: AnimatedRotation(
                  turns: refreshing ? 1 : 0,
                  duration: const Duration(milliseconds: 600),
                  child: Icon(
                    Icons.refresh_rounded,
                    size: 20,
                    color: refreshing ? AymaColors.accent : AymaColors.fgMute,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _LiveBadge(),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'What Ayma has learned about you — updated after every conversation.',
            style: TextStyle(color: AymaColors.fgMute, fontSize: 12, height: 1.5),
          ).animate(delay: 100.ms).fadeIn(duration: 400.ms),
        ],
      ),
    );
  }
}

// ── Live badge ─────────────────────────────────────────────────────────────────

class _LiveBadge extends StatefulWidget {
  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AymaColors.gold.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: AymaColors.gold.withValues(alpha: _pulse.value * 0.5),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AymaColors.gold.withValues(alpha: _pulse.value),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              'LIVE',
              style: TextStyle(
                color: AymaColors.gold.withValues(alpha: 0.7 + _pulse.value * 0.3),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Wiki card ──────────────────────────────────────────────────────────────────

class _WikiCard extends StatefulWidget {
  final _PageDef def;
  final String content;
  final Duration delay;
  const _WikiCard({
    required this.def,
    required this.content,
    required this.delay,
  });

  @override
  State<_WikiCard> createState() => _WikiCardState();
}

class _WikiCardState extends State<_WikiCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final hasContent = widget.content.trim().isNotEmpty;
    final isMedia = widget.def.key == 'media';
    final parsedMedia = isMedia ? _parseMediaEntries(widget.content) : <_MediaEntry>[];

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: HudPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Card header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AymaColors.gold.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AymaColors.gold.withValues(alpha: 0.2),
                        width: 0.5,
                      ),
                    ),
                    child: Icon(
                      widget.def.icon,
                      size: 16,
                      color: hasContent ? AymaColors.gold : AymaColors.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.def.title,
                          style: TextStyle(
                            color: hasContent
                                ? AymaColors.textPrimary
                                : AymaColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                        Text(
                          widget.def.subtitle,
                          style: TextStyle(
                            color: AymaColors.textTertiary,
                            fontSize: 10,
                            letterSpacing: 0.3,
                          ),
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

            // Divider
            if (_expanded)
              Container(
                height: 0.5,
                color: AymaColors.border,
              ),

            // Content
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: hasContent
                    ? (isMedia
                        ? _MediaContent(entries: parsedMedia, rawContent: widget.content)
                        : _TextContent(text: widget.content))
                    : _EmptyContent(hint: widget.def.emptyHint),
              ),
          ],
        ),
      )
          .animate(delay: widget.delay)
          .fadeIn(duration: 350.ms)
          .slideY(begin: 0.04, end: 0),
    );
  }
}

// ── Text content ───────────────────────────────────────────────────────────────

class _TextContent extends StatelessWidget {
  final String text;
  const _TextContent({required this.text});

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text.trim(),
      style: const TextStyle(
        color: AymaColors.textPrimary,
        fontSize: 13,
        height: 1.65,
        letterSpacing: 0.1,
      ),
    );
  }
}

// ── Media content ──────────────────────────────────────────────────────────────

class _MediaEntry {
  final String date;
  final String url;
  final String caption;
  const _MediaEntry({required this.date, required this.url, required this.caption});
}

List<_MediaEntry> _parseMediaEntries(String raw) {
  final entries = <_MediaEntry>[];
  final lines = raw.split('\n');
  String? currentDate, currentUrl, currentCaption;

  for (final line in lines) {
    final trimmed = line.trim();
    // Match: - [date](url)
    final headerMatch = RegExp(r'^\-\s*\[([^\]]+)\]\(([^)]+)\)').firstMatch(trimmed);
    if (headerMatch != null) {
      if (currentUrl != null) {
        entries.add(_MediaEntry(
          date: currentDate ?? '',
          url: currentUrl,
          caption: currentCaption?.trim() ?? '',
        ));
      }
      currentDate = headerMatch.group(1);
      currentUrl = headerMatch.group(2);
      currentCaption = '';
    } else if (currentUrl != null && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      currentCaption = (currentCaption ?? '') + (currentCaption!.isEmpty ? '' : ' ') + trimmed;
    }
  }
  if (currentUrl != null) {
    entries.add(_MediaEntry(
      date: currentDate ?? '',
      url: currentUrl,
      caption: currentCaption?.trim() ?? '',
    ));
  }
  return entries;
}

class _MediaContent extends StatelessWidget {
  final List<_MediaEntry> entries;
  final String rawContent;
  const _MediaContent({required this.entries, required this.rawContent});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return _TextContent(text: rawContent);
    }
    return Column(
      children: entries.map((e) => _MediaEntryCard(entry: e)).toList(),
    );
  }
}

class _MediaEntryCard extends StatelessWidget {
  final _MediaEntry entry;
  const _MediaEntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AymaColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AymaColors.borderSub),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AymaColors.gold.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: AymaColors.gold.withValues(alpha: 0.15),
                width: 0.5,
              ),
            ),
            child: Icon(
              Icons.image_outlined,
              size: 18,
              color: AymaColors.textTertiary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.caption.isNotEmpty)
                  Text(
                    entry.caption,
                    style: const TextStyle(
                      color: AymaColors.textPrimary,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                if (entry.date.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    entry.date,
                    style: const TextStyle(
                      color: AymaColors.textTertiary,
                      fontSize: 10,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty content ──────────────────────────────────────────────────────────────

class _EmptyContent extends StatelessWidget {
  final String hint;
  const _EmptyContent({required this.hint});

  @override
  Widget build(BuildContext context) {
    return Text(
      hint,
      style: const TextStyle(
        color: AymaColors.textTertiary,
        fontSize: 12,
        height: 1.6,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}

// ── Loading / Error ────────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
        strokeWidth: 1.5,
        color: AymaColors.gold,
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Could not load insights',
          style: TextStyle(color: AymaColors.textSecondary, fontSize: 14),
        ),
      ),
    );
  }
}

// ── Page definition ────────────────────────────────────────────────────────────

class _PageDef {
  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final String emptyHint;

  const _PageDef({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.emptyHint,
  });
}
