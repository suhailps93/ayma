class AuthUser {
  final String id;
  final String? email;

  const AuthUser({
    required this.id,
    this.email,
  });

  factory AuthUser.fromMap(Map<String, dynamic> map) {
    return AuthUser(
      id: map['id'] as String,
      email: map['email'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'email': email,
    };
  }
}

class AuthSession {
  final String accessToken;
  final String refreshToken;
  final int? expiresAt;
  final String? tokenType;
  final AuthUser user;

  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    this.expiresAt,
    this.tokenType,
  });

  factory AuthSession.fromMap(Map<String, dynamic> map) {
    return AuthSession(
      accessToken: map['access_token'] as String,
      refreshToken: map['refresh_token'] as String,
      expiresAt: map['expires_at'] as int?,
      tokenType: map['token_type'] as String?,
      user: AuthUser.fromMap(map['user'] as Map<String, dynamic>),
    );
  }

  AuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    int? expiresAt,
    String? tokenType,
    AuthUser? user,
  }) {
    return AuthSession(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      tokenType: tokenType ?? this.tokenType,
      user: user ?? this.user,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt,
      'token_type': tokenType,
      'user': user.toMap(),
    };
  }
}
