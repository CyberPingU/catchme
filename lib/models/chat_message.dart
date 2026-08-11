enum MessageType {
  text,
  photoRequest,
  photoResponse,
  photoRejected,
  locationRequest,
  locationResponse,
  locationRejected,
  image,
  file,
}

enum MessageStatus {
  sending,
  sent,
  delivered,
}

class ChatMessage {
  final String id;
  final String endpointId;
  final String message;
  final DateTime timestamp;
  final bool isSent;
  final MessageType type;
  final String? photoData; // Base64 encoded photo data (used for avatar exchange)
  final String? localFilePath; // Local file path for images and files
  final MessageStatus status;

  ChatMessage({
    required this.id,
    required this.endpointId,
    required this.message,
    required this.timestamp,
    required this.isSent,
    this.type = MessageType.text,
    this.photoData,
    this.localFilePath,
    this.status = MessageStatus.sent,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'endpointId': endpointId,
        'message': message,
        'timestamp': timestamp.toIso8601String(),
        'isSent': isSent,
        'type': type.name,
        'photoData': photoData,
        'localFilePath': localFilePath,
        'status': status.name,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        endpointId: json['endpointId'] as String,
        message: json['message'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        isSent: json['isSent'] as bool,
        type: MessageType.values.firstWhere(
          (e) => e.name == (json['type'] ?? 'text'),
          orElse: () => MessageType.text,
        ),
        photoData: json['photoData'] as String?,
        localFilePath: json['localFilePath'] as String?,
        status: MessageStatus.values.firstWhere(
          (e) => e.name == (json['status'] ?? 'sent'),
          orElse: () => MessageStatus.sent,
        ),
      );

  ChatMessage copyWith({
    MessageStatus? status,
    String? localFilePath,
  }) {
    return ChatMessage(
      id: id,
      endpointId: endpointId,
      message: message,
      timestamp: timestamp,
      isSent: isSent,
      type: type,
      photoData: photoData,
      localFilePath: localFilePath ?? this.localFilePath,
      status: status ?? this.status,
    );
  }
}
