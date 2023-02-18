library datamine_client;

import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';

class UserInfo {
  final String? displayName;
  final String? photoUrl;

  const UserInfo(this.displayName, this.photoUrl);
}

/// A client to interact with a DataMine's storage.
class DatamineClient {
  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive',
  ]);

  final _userInfoController = StreamController<UserInfo?>.broadcast();
  UserInfo? get currentUser {
    final gUser = _googleSignIn.currentUser;
    if (gUser == null) {
      return null;
    }
    return UserInfo(gUser.displayName, gUser.photoUrl);
  }

  DatamineClient() {
    _googleSignIn.onCurrentUserChanged.listen(_onUserChange);
  }

  Future<void> signIn() async {
    GoogleSignInAccount? user;
    try {
      user = await _googleSignIn.signInSilently(suppressErrors: false);
    } catch (_) {}
    if (user == null) {
      await _googleSignIn.signIn();
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.disconnect();
  }

  void _onUserChange(GoogleSignInAccount? user) async {
    if (user == null) {
      _userInfoController.add(null);
    } else {
      _userInfoController.add(UserInfo(user.displayName, user.photoUrl));
    }
  }

  /// Subscribe to this stream to be notified when the current user changes.
  Stream<UserInfo?> get onUserChanged => _userInfoController.stream;
}
