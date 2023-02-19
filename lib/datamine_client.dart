library datamine_client;

import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:package_info_plus/package_info_plus.dart';

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
      await _createFolder();
    }
  }

  Future<void> _createFolder() async {
    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    final appName = (await PackageInfo.fromPlatform()).appName;
    final dataMineDir = await _ensureFolder(api, 'my_data_mine', null);
    final appDir = await _ensureFolder(api, appName, dataMineDir.id);
    _folderId = appDir.id;
  }

  /// Subscribe to this stream to be notified when the current user changes.
  Stream<UserInfo?> get onUserChanged => _userInfoController.stream;
}

Future<drive.File> _ensureFolder(
  drive.DriveApi api,
  String name,
  String? parent,
) async {
  const folderType = 'application/vnd.google-apps.folder';

  String query = "mimeType='$folderType' and name='$name'";
  if (parent != null) query += " and '$parent' in parents";
  final list = await api.files.list(q: query);
  final files = list.files ?? [];

  if (files.length == 1) {
    return files[0];
  }
  if (files.isEmpty) {
    return api.files.create(drive.File(
      name: name,
      mimeType: folderType,
      parents: parent != null ? [parent] : null,
    ));
  }

  throw Exception("ambiguous data setup: ${files.length} folders match $name");
}
