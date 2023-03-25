import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hash/hash.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:isar/isar.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'src/local_store.dart';

final _log = Logger("datamine_client");

class UserInfo {
  final String? displayName;
  final String? email;
  final String? photoUrl;

  @override
  String toString() => "$displayName <$email>";

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
  late final Future<Isar> _dbReady =
      getApplicationSupportDirectory().then(_openDb);
  Completer<void> _onlineReady = Completer<void>();
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

    getTemporaryDirectory().then((dir) {
      _cachePath = dir.path;
      _log.finest("using $_cachePath as the download directory");
    });
  }

  Future<Isar> _openDb(Directory dir) async {
    const dbName = "data_mine_client";
    final dbFile = File(path.join(dir.path, "$dbName.isar"));

    // Database already exists, all we need to do is open it.
    if (await dbFile.exists()) {
      _log.fine("database file already exists");
      return Isar.open([FileMetaSchema], directory: dir.path, name: dbName);
    }
    _log.finer("no database found locally");

    // Next we need to check if the database has been backed up remotely.
    try {
      final dlDb = await getFile("$dbName.isar");
      await dlDb.rename(dbFile.path);
      _log.fine("downloaded database file from remote store");
      return Isar.open([FileMetaSchema], directory: dir.path, name: dbName);
    } on FileSystemException {
      // Need to create, initialize, and upload the database, but the try
      // block returns so we don't need to do that in this nested block.
      _log.finer("no database found on remote");
    }

    final files = _fileIds!.entries
        .map((ids) => FileMeta(ids.key, null, ids.value, false))
        .toList();

    final db =
        await Isar.open([FileMetaSchema], directory: dir.path, name: dbName);
    await db.writeTxn(() => db.fileMetas.putAll(files));
    _log.fine("created a fresh database");

    return db;
  }

  Future<void> signIn() async {
    GoogleSignInAccount? user;
    try {
      user = await _googleSignIn.signInSilently(suppressErrors: false);
    } catch (err) {
      _log.info("silent sign in failed", err);
    }
    if (user == null) {
      await _googleSignIn.signIn();
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.disconnect();
  }

  void _onUserChange(GoogleSignInAccount? user) async {
    if (user == null) {
      _onlineReady = Completer<void>();
      if (!_newFileSub.isPaused) {
        _log.finer("pausing file upload stream");
        _newFileSub.pause();
      }
      _fileIds = null;
      _userInfoCtrl.add(null);
    } else {
      _userInfoCtrl.add(UserInfo(user.displayName, user.email, user.photoUrl));
      await _createFolder();
      if (_newFileSub.isPaused) {
        _log.finer("resuming file upload stream");
        _newFileSub.resume();
      }
      if (!_onlineReady.isCompleted) {
        _onlineReady.complete();
      } else {
        _log.warning("unexpected user change while signed in $user");
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
      _log.fine("ignored file upload ${file.metadata.name} as a duplicate");
      return;
    }
    _log.finer("uploading file ${file.metadata.name}");
    _fileIds![file.metadata.name!] = null;
    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    file.metadata.parents = [_folderId!];
    final result =
        await api.files.create(file.metadata, uploadMedia: file.contents);
    _fileIds![result.name!] = result.id;
    _log.fine("finished uploading file ${file.metadata.name}");
  }

  Future<List<String>> listFiles() async {
    final isar = await _dbReady;
    return isar.fileMetas.where().idProperty().findAll();
  }

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

  Future<String> storeDynamicFile(File local) async {
    final name = path.basename(local.path);

    _newFileCtrl.add(_FullDriveFile(
      drive.File(name: name),
      drive.Media(local.openRead(), local.lengthSync()),
    ));
    return name;
  }

  /// Updates the content of a previously stored dynamic file.
  Future<void> updateDynamicFile(File local) async {
    await _onlineReady.future;
    final name = path.basename(local.path);
    final driveId = _fileIds?[name];
    if (driveId == null) {
      throw FileSystemException(
          "file doesn't match previously stored file", name);
    }

    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);
    await api.files.update(
      drive.File(),
      driveId,
      uploadMedia: drive.Media(local.openRead(), local.lengthSync()),
    );
  }

  Future<File> getFile(String fileId) async {
    final result = File(path.join(_cachePath, fileId));
    if (result.existsSync()) {
      _log.fine("returning file $fileId from the cache");
      return result;
    }

    await _onlineReady.future;
    final driveId = _fileIds?[fileId];
    if (driveId == null) {
      throw FileSystemException("file not found", fileId);
    }
    _log.fine("downloading file $fileId as google drive file $driveId");

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

  if (files.isEmpty) {
    _log.fine("creating new folder $name with parent $parent");
    return api.files.create(drive.File(
      name: name,
      mimeType: folderType,
      parents: parent != null ? [parent] : null,
    ));
  }

  if (files.length > 1) {
    _log.warning("ambiguous data setup: ${files.length} folders match $name");
  }
  return files[0];
}
