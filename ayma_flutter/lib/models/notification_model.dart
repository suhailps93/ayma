enum NotificationType { newMatch, agentUpdate, profileSuggestion, system }

class NotificationModel {
  final String id;
  final NotificationType type;
  final String title;
  final String body;
  final bool read;
  final DateTime createdAt;
  final Map<String, dynamic>? meta;

  const NotificationModel({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.read,
    required this.createdAt,
    this.meta,
  });

  NotificationModel copyWith({bool? read}) => NotificationModel(
    id: id, type: type, title: title, body: body,
    read: read ?? this.read, createdAt: createdAt, meta: meta,
  );

  factory NotificationModel.fromMap(Map<String, dynamic> m) => NotificationModel(
    id: m['id'] as String,
    type: notificationTypeFromWire((m['type'] as String?) ?? 'system'),
    title: (m['title'] as String?) ?? '',
    body: (m['body'] as String?) ?? '',
    read: (m['read'] as bool?) ?? false,
    createdAt: DateTime.parse(m['created_at'] as String),
    meta: (m['meta'] as Map?)?.cast<String, dynamic>(),
  );
}

NotificationType notificationTypeFromWire(String raw) {
  switch (raw) {
    case 'new_match':
      return NotificationType.newMatch;
    case 'agent_update':
      return NotificationType.agentUpdate;
    case 'profile_suggestion':
      return NotificationType.profileSuggestion;
    default:
      return NotificationType.system;
  }
}
