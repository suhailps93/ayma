// Thin auth user wrapper populated from FirebaseAuth.instance.currentUser.
class AuthUser {
  final String id;
  final String? email;

  const AuthUser({required this.id, this.email});

  factory AuthUser.fromMap(Map<String, dynamic> map) => AuthUser(
        id: map['id'] as String,
        email: map['email'] as String?,
      );

  Map<String, dynamic> toMap() => {'id': id, 'email': email};
}
