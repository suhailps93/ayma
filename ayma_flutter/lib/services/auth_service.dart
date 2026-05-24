import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuthService extends ChangeNotifier {
  AuthService() {
    FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
  }

  User? get currentUser => FirebaseAuth.instance.currentUser;
  bool get isSignedIn => currentUser != null;

  Future<bool> signIn(String email, String password) async {
    await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return true;
  }

  Future<bool> signUp(String email, String password) async {
    final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    // Create initial Firestore profile
    await FirebaseFirestore.instance
        .collection('users')
        .doc(cred.user!.uid)
        .set({
      'display_name': email.split('@').first,
      'agent_name': 'Ayma',
      'voice_preference': 'Charon',
      'matching_prefs': {},
      'onboarding_complete': false,
      'matching_paused': false,
      'profile_public_locked': false,
      'community_profile': 'dating_standard',
      'created_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return true;
  }

  Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
    notifyListeners();
  }

  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return currentUser?.getIdToken(forceRefresh);
  }
}
