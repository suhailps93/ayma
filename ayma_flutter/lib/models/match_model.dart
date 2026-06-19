class MatchModel {
  final String id;
  final String userA;
  final String userB;
  final String currentUserId;
  final double score;
  final String? rationale;
  final String status;
  final String? summaryA;
  final String? summaryB;
  final DateTime createdAt;
  final int? synergyScore;
  final String? synergySummary;
  final bool showSimulationTranscript;

  const MatchModel({
    required this.id,
    required this.userA,
    required this.userB,
    required this.currentUserId,
    required this.score,
    this.rationale,
    required this.status,
    this.summaryA,
    this.summaryB,
    required this.createdAt,
    this.synergyScore,
    this.synergySummary,
    required this.showSimulationTranscript,
  });

  factory MatchModel.fromMap(Map<String, dynamic> m, String currentUserId) {
    return MatchModel(
      id:            m['id'].toString(),
      userA:         m['user_a'] as String,
      userB:         m['user_b'] as String,
      currentUserId: currentUserId,
      score:         ((m['score'] ?? 0) as num).toDouble(),
      rationale:     m['rationale'] as String?,
      status:        (m['status'] as String?) ?? 'pending',
      summaryA:      m['summary_a'] as String?,
      summaryB:      m['summary_b'] as String?,
      createdAt:     DateTime.parse(m['created_at'] as String),
      synergyScore:  m['synergy_score'] as int?,
      synergySummary: m['synergy_summary'] as String?,
      showSimulationTranscript: (m['show_simulation_transcript'] as bool?) ?? true,
    );
  }

  // Show the summary written for the current user's side of the match.
  String get summary {
    if (userA == currentUserId) {
      return summaryA ?? summaryB ?? rationale ?? '';
    }
    return summaryB ?? summaryA ?? rationale ?? '';
  }

  int get scorePercent => (score * 100).round().clamp(0, 100);
}
