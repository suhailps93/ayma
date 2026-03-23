import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/match_model.dart';
import '../../providers/providers.dart';
import '../../theme.dart';

class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchesAsync = ref.watch(matchesProvider);

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Text('Matches',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AymaColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  )).animate().fadeIn(duration: 400.ms),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text('People Ayma thinks you\'ll connect with.',
                  style: TextStyle(color: AymaColors.textSecondary, fontSize: 13))
                  .animate(delay: 100.ms).fadeIn(),
            ),
            Expanded(
              child: matchesAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (e, _) => Center(
                  child: Text('Could not load matches',
                      style: TextStyle(color: AymaColors.textSecondary)),
                ),
                data: (matches) => matches.isEmpty
                    ? _EmptyMatches()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: matches.length,
                        itemBuilder: (_, i) => MatchCard(
                          match: matches[i],
                          delay: i * 60,
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

class _EmptyMatches extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.auto_awesome, size: 48, color: AymaColors.textTertiary),
        const SizedBox(height: 16),
        Text('No matches yet',
            style: TextStyle(color: AymaColors.textPrimary, fontSize: 16,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text('Keep talking to Ayma — matches appear\nas you share more about yourself.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AymaColors.textSecondary, fontSize: 13)),
      ],
    ).animate().fadeIn(duration: 400.ms),
  );
}

class MatchCard extends StatelessWidget {
  final MatchModel match;
  final int delay;
  const MatchCard({super.key, required this.match, this.delay = 0});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AymaColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AymaColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Avatar placeholder
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AymaColors.accent.withValues(alpha: 0.12),
                  border: Border.all(
                      color: AymaColors.accent.withValues(alpha: 0.25)),
                ),
                child: Icon(Icons.person_outline_rounded,
                    color: AymaColors.accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Match',
                  style: TextStyle(
                      color: AymaColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15),
                ),
              ),
              // Score badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AymaColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AymaColors.accent.withValues(alpha: 0.2)),
                ),
                child: Text(
                  '${match.scorePercent}%',
                  style: TextStyle(
                      color: AymaColors.accent,
                      fontWeight: FontWeight.w700,
                      fontSize: 13),
                ),
              ),
            ],
          ),

          if (match.summary.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              height: 0.5,
              color: AymaColors.border,
            ),
            const SizedBox(height: 12),
            Text(
              match.summary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AymaColors.textSecondary,
                  fontSize: 13,
                  height: 1.5),
            ),
          ],

          const SizedBox(height: 12),
          Row(
            children: [
              _StatusBadge(status: match.status),
              const Spacer(),
              Text(
                _timeAgo(match.createdAt),
                style: TextStyle(
                    color: AymaColors.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 350.ms).slideY(begin: 0.05, end: 0);
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return '${diff.inMinutes}m ago';
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = status == 'accepted'
        ? Colors.green.shade400
        : status == 'rejected'
            ? Colors.red.shade300
            : AymaColors.textTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status[0].toUpperCase() + status.substring(1),
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
      ),
    );
  }
}
