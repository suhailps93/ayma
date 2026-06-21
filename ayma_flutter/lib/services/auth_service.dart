import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'api_service.dart';
import '../providers/providers.dart';

class AuthService extends ChangeNotifier {
  final Ref _ref;

  AuthService(this._ref) {
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

    final profile = await ApiService.getProfile();
    if (profile != null) {
      final fields = <String, dynamic>{};
      if (profile.displayName.isEmpty || profile.displayName == 'User') {
        fields['display_name'] = fallbackName;
      }
      if (fields.isNotEmpty) {
        await ApiService.updateProfile(fields);
      }
    }
  }

  Future<bool> signIn(String email, String password) async {
    final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user;
    if (user != null) {
      await _ensureUserProfile(user);
      await _ref.read(audioServiceProvider).initForUser();
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
    await _ref.read(audioServiceProvider).initForUser();
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
    await _ref.read(audioServiceProvider).initForUser();
    return true;
  }

  Future<bool> signInWithApple() async {
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );

    final OAuthProvider oAuthProvider = OAuthProvider('apple.com');
    final credential = oAuthProvider.credential(
      idToken: appleCredential.identityToken,
      accessToken: appleCredential.authorizationCode,
    );

    final userCred = await FirebaseAuth.instance.signInWithCredential(credential);
    final user = userCred.user;
    if (user == null) return false;

    String? name;
    if (appleCredential.givenName != null) {
      name = appleCredential.givenName;
      if (appleCredential.familyName != null) {
        name = '$name ${appleCredential.familyName}';
      }
    }

    await _ensureUserProfile(user, displayNameHint: name);
    await _ref.read(audioServiceProvider).initForUser();
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
            await _ref.read(audioServiceProvider).initForUser();
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
    await _ref.read(audioServiceProvider).initForUser();
    return true;
  }

  Future<void> deleteAccount() async {
    final user = currentUser;
    if (user == null) return;

    // 1. Delete Firestore data while we still have a valid token
    await ApiService.deleteUserData();

    // 2. Delete Auth user
    try {
      await user.delete();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        throw Exception('Please re-authenticate before deleting your account.');
      }
      rethrow;
    }

    // 3. Sign out to clear local state
    await signOut();
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await FirebaseAuth.instance.signOut();
    await _ref.read(audioServiceProvider).clearLocalTranscript();
    notifyListeners();
  }

  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return currentUser?.getIdToken(forceRefresh);
  }
}
