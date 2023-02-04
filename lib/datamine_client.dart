library datamine_client;

import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';

/// A client to interact with a DataMine's storage.
class DatamineClient {
  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive',
  ]);

  Future<void> signIn() async {
    try {
      await _googleSignIn.signInSilently(suppressErrors: false);
    } catch (_) {
      await _googleSignIn.signIn();
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.disconnect();
  }

  Future<bool> get isLoggedIn => _googleSignIn.isSignedIn();
  String? get displayName => _googleSignIn.currentUser?.displayName;
  String? get photoUrl => _googleSignIn.currentUser?.photoUrl;
}
