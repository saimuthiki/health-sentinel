import 'enums.dart';
import 'json.dart';

/// `chat_messages`.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.threadId,
    this.attachments = const <String>[],
    this.createdAt,
    this.pending = false,
  });

  final String id;
  final ChatRole role;
  final String content;
  final String? threadId;

  /// File names shown in the bubble. The files themselves live in private
  /// storage and are reached through short-lived signed URLs.
  final List<String> attachments;

  final DateTime? createdAt;

  /// Set on the local echo of a message that has not reached the server yet.
  final bool pending;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: asString(json['id']),
        role: ChatRole.fromWire(json['role']),
        content: asString(json['content']),
        threadId: asStringOrNull(json['thread_id']),
        attachments: asStringList(json['attachments']),
        createdAt: asTimestamp(json['created_at']),
        pending: asBool(json['pending']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'role': role.wire,
        'content': content,
        'thread_id': threadId,
        'attachments': attachments,
        'created_at': timestampToJson(createdAt),
        'pending': pending,
      });
}
