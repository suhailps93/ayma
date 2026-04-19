import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/match_model.dart';
import '../../providers/providers.dart';
import '../../theme.dart';

class MatchDetailScreen extends ConsumerStatefulWidget {
  final MatchModel match;
  const MatchDetailScreen({super.key, required this.match});

  @override
  ConsumerState<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends ConsumerState<MatchDetailScreen> {
  bool _loading = false;
  String? _actionTaken; // 'accepted' | 'rejected'

  MatchModel get m => widget.match;

  Future<void> _accept() async {
    setState(() => _loading = true);
    try {
      await acceptMatch(m.id, ref);
      if (mounted) setState(() { _actionTaken = 'accepted'; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send hello: $e')),
        );
      }
    }
  }

  Future<void> _reject() async {
    setState(() => _loading = true);
    try {
      await rejectMatch(m.id, ref);
      if (mounted) {
        setState(() { _actionTaken = 'rejected'; _loading = false; });
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) context.pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not dismiss: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final seed = m.id.hashCode.abs() % 30 + 1;
    final h1 = (seed * 37) % 360;
    final h2 = (h1 + 40) % 360;

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: CustomScrollView(
        slivers: [
          // ── Photo header ────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            backgroundColor: AymaColors.bg,
            leading: IconButton(
              icon: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.4),
                ),
                child: const Icon(Icons.arrow_back_rounded, size: 18, color: Colors.white),
              ),
              onPressed: () => context.pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      HSLColor.fromAHSL(1, h1.toDouble(), 0.28, 0.30).toColor(),
                      HSLColor.fromAHSL(1, h2.toDouble(), 0.22, 0.18).toColor(),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(
                        Icons.person_outline_rounded,
                        size: 80,
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                    // Confidence badge
                    Positioned(
                      top: 80, right: 20,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AymaColors.bg.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(color: AymaColors.accent.withValues(alpha: 0.4), width: 0.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 44, height: 3,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(2),
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                              child: FractionallySizedBox(
                                widthFactor: m.score.clamp(0.0, 1.0),
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: AymaColors.accent,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${m.scorePercent}% match',
                              style: AymaFonts.mono(size: 10, color: AymaColors.accent),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Name overlay at bottom
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, AymaColors.bg.withValues(alpha: 0.9)],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Match',
                              style: AymaFonts.serif(size: 34, color: AymaColors.fg),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _timeAgo(m.createdAt),
                              style: AymaFonts.mono(size: 9, color: AymaColors.fgMute),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Content ─────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
            sliver: SliverList(
              delegate: SliverChildListDelegate([

                // ── Ayma's reasoning ──────────────────────────────
                if (m.summary.isNotEmpty) ...[
                  _ReasoningCard(match: m)
                      .animate().fadeIn(duration: 300.ms).slideY(begin: 0.04, end: 0),
                  const SizedBox(height: 16),
                ],

                // ── Match status ──────────────────────────────────
                if (m.status != 'pending') ...[
                  _StatusBanner(status: m.status)
                      .animate().fadeIn(duration: 300.ms),
                  const SizedBox(height: 16),
                ],

                // ── About them (summaryB if we're userA, else summaryA) ──
                if (m.rationale != null && m.rationale!.isNotEmpty) ...[
                  _InfoCard(
                    title: 'Background',
                    content: m.rationale!,
                  ).animate(delay: 80.ms).fadeIn(duration: 300.ms).slideY(begin: 0.04, end: 0),
                  const SizedBox(height: 16),
                ],

                // ── Curated today label ───────────────────────────
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Row(
                    children: [
                      Expanded(child: Container(height: 0.5, color: AymaColors.lineSoft)),
                      const SizedBox(width: 14),
                      Text('CURATED BY AYMA', style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
                      const SizedBox(width: 14),
                      Expanded(child: Container(height: 0.5, color: AymaColors.lineSoft)),
                    ],
                  ),
                ),

              ]),
            ),
          ),
        ],
      ),

      // ── Action bar ──────────────────────────────────────────────
      bottomNavigationBar: _ActionBar(
        actionTaken: _actionTaken,
        status: m.status,
        loading: _loading,
        onAccept: _accept,
        onReject: _reject,
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 1) return '${diff.inDays} days ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inHours > 0) return 'Today · ${diff.inHours}h ago';
    return 'Today · just now';
  }
}

// ── Reasoning card ────────────────────────────────────────────────────────────

class _ReasoningCard extends StatelessWidget {
  final MatchModel match;
  const _ReasoningCard({required this.match});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _MiniOrb(),
              const SizedBox(width: 8),
              Text('WHY AYMA CHOSE THEM', style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '"${match.summary}"',
            style: AymaFonts.serif(size: 19, italic: true, color: AymaColors.fg),
          ),
        ],
      ),
    );
  }
}

// ── Info card ─────────────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final String title;
  final String content;
  const _InfoCard({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(
              fontSize: 14,
              color: AymaColors.fgDim,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Status banner ─────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final String status;
  const _StatusBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final isAccepted = status == 'accepted';
    final color = isAccepted ? Colors.green.shade400 : AymaColors.fgMute;
    final label = isAccepted ? 'You sent a hello' : 'Dismissed';
    final icon = isAccepted ? Icons.check_circle_outline_rounded : Icons.cancel_outlined;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// ── Action bar ────────────────────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  final String? actionTaken;
  final String status;
  final bool loading;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _ActionBar({
    required this.actionTaken,
    required this.status,
    required this.loading,
    required this.onAccept,
    required this.onReject,
  });

  bool get _alreadyActed => actionTaken != null || status != 'pending';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: _alreadyActed
            ? Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AymaColors.bgElev,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                ),
                child: Center(
                  child: Text(
                    actionTaken == 'accepted' || status == 'accepted'
                        ? 'Hello sent ✓'
                        : 'Dismissed',
                    style: const TextStyle(color: AymaColors.fgDim, fontSize: 14),
                  ),
                ),
              )
            : Row(
                children: [
                  // Not for me
                  Expanded(
                    child: GestureDetector(
                      onTap: loading ? null : onReject,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          color: AymaColors.bgElev,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
                        ),
                        child: Center(
                          child: Text(
                            'Not for me',
                            style: TextStyle(
                              fontSize: 14,
                              color: loading ? AymaColors.fgMute : AymaColors.fgDim,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Send a hello
                  Expanded(
                    flex: 2,
                    child: GestureDetector(
                      onTap: loading ? null : onAccept,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          color: AymaColors.fg,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Center(
                          child: loading
                              ? const SizedBox(
                                  width: 18, height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6, height: 6,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AymaColors.accent,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'Send a hello',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
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
          colors: [Color(0xFFEBD5A8), AymaColors.accent, Color(0xFF5A3A08)],
          stops: [0.0, 0.5, 1.0],
        ),
        boxShadow: [
          BoxShadow(color: AymaColors.accent.withValues(alpha: 0.4), blurRadius: 6),
        ],
      ),
    );
  }
}
