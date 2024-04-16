import 'dart:async';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import './backends.dart';

class GDriveBackend implements Backend, IDMapRemote {
  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive.file',
  ]);
  String _rootFolder = '';
  Completer<drive.DriveApi> _ready = Completer();
  Completer<IDMapCache> _idCache = Completer();

  GDriveBackend() {
    _googleSignIn.onCurrentUserChanged.listen(_onUserChange);
  }

  @override
  Future<UserInfo?> signIn() async {
    GoogleSignInAccount? user;
    try {
      user = await _googleSignIn.signInSilently(
          suppressErrors: false, reAuthenticate: true);
    } catch (err) {
      log.info("silent sign in failed", err);
    }
    return _convertUser(user ?? await _googleSignIn.signIn());
  }

  @override
  Future<void> signOut() {
    _idCache = Completer();
    return _googleSignIn.signOut();
  }

  @override
  void addIDCache(IDMapCache cache) {
    cache.addRemote(this);
    _idCache.complete(cache);
  }

  void _onUserChange(GoogleSignInAccount? user) async {
    // We don't expect a non-null user to come through if `ready` is
    // already complete, but if it does happen we want to get a new API
    // that will use the new credentials (that should last longer).
    if (_ready.isCompleted) {
      _ready = Completer();
      if (user != null) {
        log.warning("unexpected user change while signed in $user");
      }
    }
    if (user == null) return;

    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    String? prevId;
    for (final name in ["my_data_mine", await appName]) {
      prevId = await _ensureFolder(api, name, prevId);
    }
    _rootFolder = prevId!;

    _ready.complete(api);
  }

  @override
  Future<Map<String, String>> readFolder() async {
    const orderBy = "createdTime desc";
    final api = await _ready.future;
    final query = "'$_rootFolder' in parents";

    final Map<String, String> result = {};
    String? nextPage;
    do {
      final list = await api.files.list(
        q: query,
        orderBy: orderBy,
        pageToken: nextPage,
      );
      result.addAll({for (final f in list.files!) f.name!: f.id!});
      nextPage = list.nextPageToken;
    } while (nextPage != null);

    return result;
  }

  @override
  Future<File> downloadFile(String fileName, String destination) async {
    final idCache = await _idCache.future;
    final driveId = await idCache.getID(fileName);
    if (driveId == null) {
      throw FileSystemException("file not found", fileName);
    }
    log.fine("downloading file $fileName as google drive file $driveId");
    final api = await _ready.future;
    final driveFile = await api.files.get(driveId,
        downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;

    final result = File(destination);
    final sink = result.openWrite();
    await sink.addStream(driveFile.stream);
    await sink.close();
    return result;
  }

  @override
  Future<void> uploadFile(String fileName, File contents) async {
    final idCache = await _idCache.future;
    final api = await _ready.future;
    final media = drive.Media(contents.openRead(), await contents.length());
    final drive.File resp;

    String? remoteId = await idCache.getID(fileName);
    if (remoteId == null) {
      remoteId = (await _getFileInfo(api, fileName, parent: _rootFolder))?.id;
    }
    if (remoteId == null) {
      log.finer("creating new file $fileName");
      final driveFile = drive.File(name: fileName, parents: [_rootFolder]);
      resp = await api.files.create(driveFile, uploadMedia: media);
    } else {
      final driveFile = drive.File(name: fileName);
      log.finer("updating file $fileName (drive ID = $remoteId)");
      resp = await api.files.update(driveFile, remoteId, uploadMedia: media);
    }
    idCache.setID(fileName, resp.id);
  }
}

UserInfo? _convertUser(GoogleSignInAccount? gUser) {
  if (gUser == null) return null;
  return UserInfo(gUser.email, gUser.displayName, gUser.photoUrl);
}

Future<String> _ensureFolder(
  drive.DriveApi api,
  String name,
  String? parent,
) async {
  const folderType = 'application/vnd.google-apps.folder';

  final file =
      await _getFileInfo(api, name, parent: parent, mimeType: folderType);
  if (file != null) return file.id!;

  log.fine("creating new folder $name with parent $parent");
  final newFolder = await api.files.create(drive.File(
    name: name,
    mimeType: folderType,
    parents: parent != null ? [parent] : null,
  ));
  return newFolder.id!;
}

Future<drive.File?> _getFileInfo(
  drive.DriveApi api,
  String name, {
  String? parent,
  String? mimeType,
}) async {
  String query = "name='$name'";
  if (parent != null) query += " and '$parent' in parents";
  if (mimeType != null) query += " and mimeType='$mimeType'";

  final list = await api.files.list(q: query);
  final files = list.files ?? [];

  if (files.isEmpty) return null;
  if (files.length > 1) {
    log.warning("ambiguous remote: ${files.length} files match $name");
  }
  return files[0];
}
