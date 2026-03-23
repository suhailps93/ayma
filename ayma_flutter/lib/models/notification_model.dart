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
}
