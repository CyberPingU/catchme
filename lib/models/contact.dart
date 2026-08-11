class Contact {
  final String id; // Hash della chiave pubblica
  final String nickname;
  final String publicKey;
  final String? avatarPath;
  final DateTime dateMatched;
  final bool isBlocked;
  final DateTime? birthDate;
  final String? gender;
  final String? bio;
  final DateTime? lastSeen;
  final double? lastDistance;
  final String group;
  final bool isLocationShared;
  final String x25519PublicKey;
  final bool proximityAlertEnabled;

  Contact({
    required this.id,
    required this.nickname,
    required this.publicKey,
    this.avatarPath,
    required this.dateMatched,
    this.isBlocked = false,
    this.birthDate,
    this.gender,
    this.bio,
    this.lastSeen,
    this.lastDistance,
    this.group = 'Nuovi',
    this.isLocationShared = false,
    this.x25519PublicKey = '',
    this.proximityAlertEnabled = false,
  });

  int? get age {
    if (birthDate == null) return null;
    final today = DateTime.now();
    int calculatedAge = today.year - birthDate!.year;
    if (today.month < birthDate!.month ||
        (today.month == birthDate!.month && today.day < birthDate!.day)) {
      calculatedAge--;
    }
    return calculatedAge;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nickname': nickname,
        'publicKey': publicKey,
        'avatarPath': avatarPath,
        'dateMatched': dateMatched.toIso8601String(),
        'isBlocked': isBlocked,
        'birthDate': birthDate?.toIso8601String(),
        'gender': gender,
        'bio': bio,
        'lastSeen': lastSeen?.toIso8601String(),
        'lastDistance': lastDistance,
        'group': group,
        'isLocationShared': isLocationShared,
        'x25519PublicKey': x25519PublicKey,
        'proximityAlertEnabled': proximityAlertEnabled,
      };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'] as String,
        nickname: json['nickname'] as String,
        publicKey: json['publicKey'] as String,
        avatarPath: json['avatarPath'] as String?,
        dateMatched: DateTime.parse(json['dateMatched'] as String),
        isBlocked: json['isBlocked'] as bool? ?? false,
        birthDate: json['birthDate'] != null ? DateTime.parse(json['birthDate'] as String) : null,
        gender: json['gender'] as String?,
        bio: json['bio'] as String?,
        lastSeen: json['lastSeen'] != null ? DateTime.parse(json['lastSeen'] as String) : null,
        lastDistance: json['lastDistance'] != null ? (json['lastDistance'] as num).toDouble() : null,
        group: json['group'] as String? ?? 'Nuovi',
        isLocationShared: json['isLocationShared'] as bool? ?? false,
        x25519PublicKey: json['x25519PublicKey'] as String? ?? '',
        proximityAlertEnabled: json['proximityAlertEnabled'] as bool? ?? false,
      );

  Contact copyWith({
    String? id,
    String? nickname,
    String? publicKey,
    String? avatarPath,
    DateTime? dateMatched,
    bool? isBlocked,
    DateTime? birthDate,
    String? gender,
    String? bio,
    DateTime? lastSeen,
    double? lastDistance,
    String? group,
    bool? isLocationShared,
    String? x25519PublicKey,
    bool? proximityAlertEnabled,
  }) =>
      Contact(
        id: id ?? this.id,
        nickname: nickname ?? this.nickname,
        publicKey: publicKey ?? this.publicKey,
        avatarPath: avatarPath ?? this.avatarPath,
        dateMatched: dateMatched ?? this.dateMatched,
        isBlocked: isBlocked ?? this.isBlocked,
        birthDate: birthDate ?? this.birthDate,
        gender: gender ?? this.gender,
        bio: bio ?? this.bio,
        lastSeen: lastSeen ?? this.lastSeen,
        lastDistance: lastDistance ?? this.lastDistance,
        group: group ?? this.group,
        isLocationShared: isLocationShared ?? this.isLocationShared,
        x25519PublicKey: x25519PublicKey ?? this.x25519PublicKey,
        proximityAlertEnabled: proximityAlertEnabled ?? this.proximityAlertEnabled,
      );
}
