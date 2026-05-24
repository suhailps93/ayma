import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService extends ChangeNotifier {
  AuthService() {
    FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
  }

  final GoogleSignIn _googleSignIn = GoogleSignIn();

  User? get currentUser => FirebaseAuth.instance.currentUser;
  bool get isSignedIn => currentUser != null;

  Future<void> _ensureUserProfile(User user, {String? displayNameHint}) async {
    final fallbackName = displayNameHint?.trim().isNotEmpty == true
        ? displayNameHint!.trim()
        : (user.displayName?.trim().isNotEmpty == true
            ? user.displayName!.trim()
            : (user.email?.split('@').first ?? 'User'));

    final ref = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final snap = await ref.get();
    final exists = snap.exists;
    final data = snap.data() ?? const <String, dynamic>{};

    await ref.set({
      'display_name': fallbackName,
      'agent_name': data['agent_name'] ?? 'Ayma',
      'voice_preference': data['voice_preference'] ?? 'Charon',
      'matching_prefs': data['matching_prefs'] ?? {},
      // Preserve onboarding flag once user completed it.
      'onboarding_complete': exists
          ? (data['onboarding_complete'] as bool? ?? false)
          : false,
      'matching_paused': data['matching_paused'] ?? false,
      'profile_public_locked': data['profile_public_locked'] ?? false,
      'community_profile': data['community_profile'] ?? 'dating_standard',
      'phone_number': user.phoneNumber,
      'email': user.email,
      'last_sign_in_at': FieldValue.serverTimestamp(),
      if (!exists) 'created_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<bool> signIn(String email, String password) async {
    final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user;
    if (user != null) {
      await _ensureUserProfile(user);
    }
    return true;
  }

  Future<bool> signUp(String email, String password) async {
    final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user;
    if (user == null) return false;
    await _ensureUserProfile(user, displayNameHint: email.split('@').first);
    return true;
  }

  Future<bool> signInWithGoogle() async {
    final account = await _googleSignIn.signIn();
    if (account == null) return false;
    final auth = await account.authentication;

    final credential = GoogleAuthProvider.credential(
      idToken: auth.idToken,
      accessToken: auth.accessToken,
    );

    final userCred =
        await FirebaseAuth.instance.signInWithCredential(credential);
    final user = userCred.user;
    if (user == null) return false;

    await _ensureUserProfile(user);
    return true;
  }

  Future<String> sendPhoneOtp(String phoneNumber) async {
    final completer = Completer<String>();

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phoneNumber.trim(),
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        if (FirebaseAuth.instance.currentUser == null) {
          final userCred =
              await FirebaseAuth.instance.signInWithCredential(credential);
          final user = userCred.user;
          if (user != null) {
            await _ensureUserProfile(user);
          }
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      codeSent: (String verificationId, int? resendToken) {
        if (!completer.isCompleted) {
          completer.complete(verificationId);
        }
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        if (!completer.isCompleted) {
          completer.complete(verificationId);
        }
      },
    );

    return completer.future;
  }

  Future<bool> verifyPhoneOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode.trim(),
    );

    final userCred = await FirebaseAuth.instance.signInWithCredential(credential);
    final user = userCred.user;
    if (user == null) return false;

    await _ensureUserProfile(user);
    return true;
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await FirebaseAuth.instance.signOut();
    notifyListeners();
  }

  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return currentUser?.getIdToken(forceRefresh);
  }
}
