library datamine_client;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hash/hash.dart';
import 'package:path/path.dart' as path;

import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UserInfo {
  final String? displayName;
  final String? email;
  final String? photoUrl;

  const UserInfo(this.displayName, this.email, this.photoUrl);
}

class _FullDriveFile {
  final drive.File metadata;
  final drive.Media contents;
  const _FullDriveFile(this.metadata, this.contents);
}

/// A client to interact with a DataMine's storage.
class DatamineClient {
  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive.file',
  ]);
  String? _folderId;
  Map<String, String?>? _fileIds;
  final _newFileCtrl = StreamController<_FullDriveFile>();
  late final StreamSubscription<_FullDriveFile> _newFileSub;
  late final String _cachePath;

  final _userInfoCtrl = StreamController<UserInfo?>.broadcast();
  UserInfo? get currentUser {
    final gUser = _googleSignIn.currentUser;
    if (gUser == null) {
      return null;
    }
    return UserInfo(gUser.displayName, gUser.email, gUser.photoUrl);
  }

  DatamineClient() {
    _newFileSub = _newFileCtrl.stream.listen(_onNewFile);
    _newFileSub.pause();
    _googleSignIn.onCurrentUserChanged.listen(_onUserChange);

    getTemporaryDirectory().then((dir) => _cachePath = dir.path);
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
      if (!_newFileSub.isPaused) {
        _newFileSub.pause();
      }
      _fileIds = null;
      _userInfoCtrl.add(null);
    } else {
      _userInfoCtrl.add(UserInfo(user.displayName, user.email, user.photoUrl));
      await _createFolder();
      if (_newFileSub.isPaused) {
        _newFileSub.resume();
      }
    }
  }

  Future<void> _createFolder() async {
    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    final appName = (await PackageInfo.fromPlatform()).appName;
    final dataMineDir = await _ensureFolder(api, 'my_data_mine', null);
    final appDir = await _ensureFolder(api, appName, dataMineDir.id);
    _folderId = appDir.id;

    final list = await api.files.list(q: "'$_folderId' in parents");
    _fileIds = {for (drive.File f in list.files ?? []) f.name!: f.id!};
  }

  void _onNewFile(_FullDriveFile file) async {
    if (_fileIds!.containsKey(file.metadata.name!)) {
      return;
    }
    _fileIds![file.metadata.name!] = null;
    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    file.metadata.parents = [_folderId!];
    final result =
        await api.files.create(file.metadata, uploadMedia: file.contents);
    _fileIds![result.name!] = result.id;
  }

  List<String> listFiles() => _fileIds?.keys.toList() ?? [];

  Future<String> storeFile(File local) async {
    final rawHash = SHA256();
    await for (List<int> chunk in local.openRead()) {
      rawHash.update(chunk);
    }
    final b64Hash = base64UrlEncode(rawHash.digest());

    _newFileCtrl.add(_FullDriveFile(
      drive.File(
        name: b64Hash,
        originalFilename: path.basename(local.path),
      ),
      drive.Media(local.openRead(), local.lengthSync()),
    ));
    return b64Hash;
  }

  Future<File> getFile(String fileId) async {
    final result = File(path.join(_cachePath, fileId));
    if (result.existsSync()) {
      return result;
    }

    final driveId = _fileIds?[fileId];
    if (driveId == null) {
      throw FileSystemException("file not found", fileId);
    }

    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);
    final driveFile = await api.files.get(driveId,
        downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;

    final sink = result.openWrite();
    await sink.addStream(driveFile.stream);
    await sink.close();
    return result;
  }

  /// Subscribe to this stream to be notified when the current user changes.
  Stream<UserInfo?> get onUserChanged => _userInfoCtrl.stream;
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
