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
  });

  factory MatchModel.fromMap(Map<String, dynamic> m, String currentUserId) {
    return MatchModel(
      id:            m['id'] as String,
      userA:         m['user_a'] as String,
      userB:         m['user_b'] as String,
      currentUserId: currentUserId,
      score:         ((m['score'] ?? 0) as num).toDouble(),
      rationale:     m['rationale'] as String?,
      status:        (m['status'] as String?) ?? 'pending',
      summaryA:      m['summary_a'] as String?,
      summaryB:      m['summary_b'] as String?,
      createdAt:     DateTime.parse(m['created_at'] as String),
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
