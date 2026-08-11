class NearbyUser {
  final String endpointId;
  final String nickname;
  final String status;
  final bool isConnected;
  final bool isPending;
  final String? publicKey;
  final bool isVerified; // Contatto già salvato e verificato
  final bool isTrusted; // Firma verificata durante l'handshake
  final DateTime? birthDate;
  final String? gender;
  final String? bio;
  final String? x25519PublicKey;

  NearbyUser({
    required this.endpointId,
    required this.nickname,
    required this.status,
    this.isConnected = false,
    this.isPending = false,
    this.publicKey,
    this.isVerified = false,
    this.isTrusted = false,
    this.birthDate,
    this.gender,
    this.bio,
    this.x25519PublicKey,
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

  NearbyUser copyWith({
    String? endpointId,
    String? nickname,
    String? status,
    bool? isConnected,
    bool? isPending,
    String? publicKey,
    bool? isVerified,
    bool? isTrusted,
    DateTime? birthDate,
    String? gender,
    String? bio,
    String? x25519PublicKey,
  }) =>
      NearbyUser(
        endpointId: endpointId ?? this.endpointId,
        nickname: nickname ?? this.nickname,
        status: status ?? this.status,
        isConnected: isConnected ?? this.isConnected,
        isPending: isPending ?? this.isPending,
        publicKey: publicKey ?? this.publicKey,
        isVerified: isVerified ?? this.isVerified,
        isTrusted: isTrusted ?? this.isTrusted,
        birthDate: birthDate ?? this.birthDate,
        gender: gender ?? this.gender,
        bio: bio ?? this.bio,
        x25519PublicKey: x25519PublicKey ?? this.x25519PublicKey,
      );
}
