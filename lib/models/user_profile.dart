class UserProfile {
  final String nickname;
  final UserStatus status;
  final DateTime? birthDate;
  final String? gender;
  final String? bio;
  final String? avatarPath;
  final String? publicKey;
  final String? x25519PublicKey;
  final String pushProvider;
  final String? pushToken;
  final int radarRange;

  UserProfile({
    required this.nickname,
    required this.status,
    this.birthDate,
    this.gender,
    this.bio,
    this.avatarPath,
    this.publicKey,
    this.x25519PublicKey,
    this.pushProvider = 'fcm',
    this.pushToken,
    this.radarRange = 500,
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
        'nickname': nickname,
        'status': status.name,
        'birthDate': birthDate?.toIso8601String(),
        'gender': gender,
        'bio': bio,
        'avatarPath': avatarPath,
        'publicKey': publicKey,
        'x25519PublicKey': x25519PublicKey,
        'pushProvider': pushProvider,
        'pushToken': pushToken,
        'radarRange': radarRange,
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        nickname: json['nickname'] as String,
        status: UserStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => UserStatus.unavailable,
        ),
        birthDate: json['birthDate'] != null ? DateTime.parse(json['birthDate'] as String) : null,
        gender: json['gender'] as String?,
        bio: json['bio'] as String?,
        avatarPath: json['avatarPath'] as String?,
        publicKey: json['publicKey'] as String?,
        x25519PublicKey: json['x25519PublicKey'] as String?,
        pushProvider: (json['pushProvider'] as String?) ?? 'fcm',
        pushToken: json['pushToken'] as String?,
        radarRange: json['radarRange'] as int? ?? 500,
      );

  UserProfile copyWith({
    String? nickname,
    UserStatus? status,
    DateTime? birthDate,
    String? gender,
    String? bio,
    String? avatarPath,
    String? publicKey,
    String? x25519PublicKey,
    String? pushProvider,
    String? pushToken,
    int? radarRange,
  }) =>
      UserProfile(
        nickname: nickname ?? this.nickname,
        status: status ?? this.status,
        birthDate: birthDate ?? this.birthDate,
        gender: gender ?? this.gender,
        bio: bio ?? this.bio,
        avatarPath: avatarPath ?? this.avatarPath,
        publicKey: publicKey ?? this.publicKey,
        x25519PublicKey: x25519PublicKey ?? this.x25519PublicKey,
        pushProvider: pushProvider ?? this.pushProvider,
        pushToken: pushToken ?? this.pushToken,
        radarRange: radarRange ?? this.radarRange,
      );
}

enum UserStatus {
  available,
  unavailable,
  invisible;

  String get displayName {
    switch (this) {
      case UserStatus.available:
        return 'Disponibile';
      case UserStatus.unavailable:
        return 'Non Disponibile';
      case UserStatus.invisible:
        return 'Invisibile';
    }
  }
}
