import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/match_model.dart';
import '../../providers/providers.dart';
import '../../services/backend_service.dart';
import '../../theme.dart';
import 'match_detail_screen.dart';

class MatchesScreen extends ConsumerStatefulWidget {
  const MatchesScreen({super.key});

  @override
  ConsumerState<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends ConsumerState<MatchesScreen> {
  bool _running = false;

  Future<void> _triggerMatching() async {
    setState(() => _running = true);
    try {
      final result = await BackendService.runMatching();
      ref.invalidate(matchesProvider);
      if (mounted) {
        final created = result['matches_created'] as int? ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              created == 0
                  ? 'No new matches this time — check back later.'
                  : 'Found $created new match${created != 1 ? 'es' : ''}!',
            ),
            backgroundColor: AymaColors.bgElev,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Matching failed: $e'),
            backgroundColor: AymaColors.bgElev,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matchesAsync = ref.watch(matchesProvider);

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        bottom: false,
        child: matchesAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AymaColors.accent,
            ),
          ),
          error: (e, _) => Center(
            child: Text(
              'Could not load matches',
              style: TextStyle(color: AymaColors.fgDim, fontSize: 14),
            ),
          ),
          data: (matches) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            matches.isEmpty
                                ? 'No introductions yet'
                                : '${matches.length} introduction${matches.length != 1 ? 's' : ''} · curated today',
                            style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
                          ).animate().fadeIn(duration: 300.ms),
                        ),
                        _RunMatchingButton(
                          running: _running,
                          onTap: _running ? null : _triggerMatching,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'People Ayma picked',
                      style: AymaFonts.serif(size: 36, color: AymaColors.fg),
                    ).animate(delay: 60.ms).fadeIn(duration: 400.ms),
                    const SizedBox(height: 8),
                    Text(
                      'Your photos are only shared when you say yes.',
                      style: TextStyle(
                        fontSize: 13,
                        color: AymaColors.fgDim,
                        height: 1.5,
                      ),
                    ).animate(delay: 120.ms).fadeIn(),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              Expanded(
                child: matches.isEmpty
                    ? _EmptyMatches(running: _running, onRunMatching: _triggerMatching)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                        itemCount: matches.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: MatchCard(
                            match: matches[i],
                            featured: i == 0,
                            delay: i * 60,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunMatchingButton extends StatelessWidget {
  final bool running;
  final VoidCallback? onTap;

  const _RunMatchingButton({required this.running, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running)
              const SizedBox(
                width: 10, height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AymaColors.accent,
                ),
              )
            else
              Container(
                width: 6, height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AymaColors.accent,
                ),
              ),
            const SizedBox(width: 6),
            Text(
              running ? 'Finding…' : 'Find matches',
              style: const TextStyle(
                fontSize: 12,
                color: AymaColors.fgDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyMatches extends StatelessWidget {
  final bool running;
  final VoidCallback onRunMatching;

  const _EmptyMatches({required this.running, required this.onRunMatching});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AymaColors.accent.withValues(alpha: 0.3),
                    AymaColors.accent.withValues(alpha: 0.05),
                  ],
                ),
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: AymaColors.accent, size: 28),
            ),
            const SizedBox(height: 20),
            Text(
              'Ayma is still getting to know you',
              style: AymaFonts.serif(size: 22, color: AymaColors.fg),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Keep talking — matches appear as you share more about yourself.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AymaColors.fgDim, fontSize: 13, height: 1.55),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: running ? null : onRunMatching,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  color: AymaColors.bgElev,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (running)
                      const SizedBox(
                        width: 12, height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AymaColors.accent,
                        ),
                      )
                    else
                      Container(
                        width: 6, height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AymaColors.accent,
                        ),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      running ? 'Finding matches…' : 'Find matches now',
                      style: const TextStyle(
                        fontSize: 14,
                        color: AymaColors.fg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ).animate().fadeIn(duration: 400.ms),
    );
  }
}

class MatchCard extends ConsumerStatefulWidget {
  final MatchModel match;
  final bool featured;
  final int delay;

  const MatchCard({
    super.key,
    required this.match,
    this.featured = false,
    this.delay = 0,
  });

  @override
  ConsumerState<MatchCard> createState() => _MatchCardState();
}

class _MatchCardState extends ConsumerState<MatchCard> {
  bool _acting = false;
  String? _localStatus; // optimistic override

  MatchModel get m => widget.match;

  Future<void> _accept() async {
    setState(() => _acting = true);
    try {
      await acceptMatch(m.id, ref);
      if (mounted) setState(() { _localStatus = 'accepted'; _acting = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _acting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send hello: $e')),
        );
      }
    }
  }

  Future<void> _reject() async {
    setState(() => _acting = true);
    try {
      await rejectMatch(m.id, ref);
      if (mounted) setState(() { _localStatus = 'rejected'; _acting = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _acting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not dismiss: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveStatus = _localStatus ?? m.status;
    final seed = m.id.hashCode.abs() % 30 + 1;
    final h1 = (seed * 37) % 360;
    final h2 = (h1 + 40) % 360;

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MatchDetailScreen(match: m)),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: AymaColors.bgElev,
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            // Photo + name row
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Photo placeholder
                  SizedBox(
                    width: 130,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            HSLColor.fromAHSL(1, h1.toDouble(), 0.28, 0.28).toColor(),
                            HSLColor.fromAHSL(1, h2.toDouble(), 0.22, 0.20).toColor(),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.person_outline_rounded,
                          size: 40,
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                    ),
                  ),
                  // Info panel
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Match',
                                style: AymaFonts.serif(size: 24, color: AymaColors.fg),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _timeAgo(m.createdAt),
                                style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              _ConfidenceBar(value: m.score),
                              const SizedBox(width: 8),
                              Text(
                                '${m.scorePercent}%',
                                style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
                              ),
                              const Spacer(),
                              if (effectiveStatus != 'pending')
                                _StatusPill(status: effectiveStatus)
                              else
                                const Icon(Icons.chevron_right_rounded,
                                    size: 16, color: AymaColors.fgMute),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Ayma's reasoning
            if (m.summary.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: AymaColors.lineSoft, width: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _MiniOrb(),
                        const SizedBox(width: 8),
                        Text('WHY I CHOSE THEM',
                            style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '"${m.summary}"',
                      style: AymaFonts.serif(size: 17, italic: true, color: AymaColors.fg),
                    ),
                    if (m.rationale != null && m.rationale != m.summary) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 4, height: 4,
                            margin: const EdgeInsets.only(top: 8, right: 10),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AymaColors.accent,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              m.rationale!,
                              style: const TextStyle(
                                  fontSize: 13, color: AymaColors.fgDim, height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

            // Actions — show status if acted, otherwise show buttons
            if (effectiveStatus != 'pending')
              _ActedRow(status: effectiveStatus)
            else
              Row(
                children: [
                  Expanded(
                    child: _MatchAction(
                      label: _acting ? '…' : 'Not for me',
                      dim: true,
                      hasBorder: true,
                      onTap: _acting ? null : _reject,
                    ),
                  ),
                  Expanded(
                    child: _MatchAction(
                      label: _acting ? '…' : 'Send a hello',
                      dim: false,
                      accent: true,
                      hasBorder: false,
                      onTap: _acting ? null : _accept,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: widget.delay)).fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0);
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 1) return '${diff.inDays} days ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inHours > 0) return 'Today · ${diff.inHours}h ago';
    return 'Today · just now';
  }
}

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});
  @override
  Widget build(BuildContext context) {
    final isAccepted = status == 'accepted';
    final color = isAccepted ? Colors.green.shade400 : AymaColors.fgMute;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isAccepted ? 'Sent ✓' : 'Dismissed',
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _ActedRow extends StatelessWidget {
  final String status;
  const _ActedRow({required this.status});
  @override
  Widget build(BuildContext context) {
    final isAccepted = status == 'accepted';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AymaColors.lineSoft, width: 0.5)),
      ),
      child: Center(
        child: Text(
          isAccepted ? 'Hello sent ✓' : 'Dismissed',
          style: TextStyle(
            fontSize: 13,
            color: isAccepted ? Colors.green.shade400 : AymaColors.fgMute,
          ),
        ),
      ),
    );
  }
}

class _MatchAction extends StatelessWidget {
  final String label;
  final bool dim;
  final bool accent;
  final bool hasBorder;
  final VoidCallback? onTap;

  const _MatchAction({
    required this.label,
    required this.dim,
    required this.hasBorder,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          border: Border(
            top: const BorderSide(color: AymaColors.lineSoft, width: 0.5),
            right: hasBorder
                ? const BorderSide(color: AymaColors.lineSoft, width: 0.5)
                : BorderSide.none,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (accent) ...[
              Container(
                width: 6, height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AymaColors.accent,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: dim ? AymaColors.fgDim : AymaColors.fg,
                fontWeight: accent ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfidenceBar extends StatelessWidget {
  final double value;
  const _ConfidenceBar({required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 3,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(2),
      ),
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0),
        alignment: Alignment.centerLeft,
        child: Container(
          decoration: BoxDecoration(
            color: AymaColors.accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _MiniOrb extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14, height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.3, -0.3),
          colors: [
            Color(0xFFEBD5A8),
            AymaColors.accent,
            Color(0xFF5A3A08),
          ],
          stops: [0.0, 0.5, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: AymaColors.accent.withValues(alpha: 0.4),
            blurRadius: 6,
          ),
        ],
      ),
    );
  }
}
