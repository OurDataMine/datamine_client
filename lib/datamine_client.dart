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
import 'package:shared_preferences/shared_preferences.dart';

import 'src/drive_helpers.dart';
import 'src/local_store.dart';

final _log = Logger("datamine_client");

class UserInfo {
  final String email;
  final String? displayName;
  final String? photoUrl;

  @override
  String toString() => "$displayName <$email>";

  const UserInfo(this.email, this.displayName, this.photoUrl);
  static UserInfo? _fromGoogle(GoogleSignInAccount? gUser) {
    if (gUser == null) return null;
    return UserInfo(gUser.email, gUser.displayName, gUser.photoUrl);
  }
}

/// A client to interact with a DataMine's storage.
class DatamineClient {
  static const _prefix = "_dmc";
  static const _userKey = "$_prefix:current_user";
  static const _dbName = "data_mine_client";

  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive.file',
  ]);
  late final SharedPreferences _pref;
  late final String _cacheRoot;
  late String _cachePath;
  String? _folderID;
  Map<String, String>? _fileIDs;

  late final Future<Isar> _dbReady =
      getApplicationSupportDirectory().then(_openDb);
  Completer<void> _onlineReady = Completer<void>();

  /// User info for the account used to sign in.
  UserInfo? get currentUser => UserInfo._fromGoogle(_googleSignIn.currentUser);

  /// Subscribe to this stream to be notified when the current user changes.
  late final Stream<UserInfo?> onUserChanged =
      _googleSignIn.onCurrentUserChanged.map(UserInfo._fromGoogle);

  DatamineClient() {
    _dbReady.then(_watchUploads);
    _googleSignIn.onCurrentUserChanged.listen(_onUserChange);

    Future.wait([
      SharedPreferences.getInstance().then((val) => _pref = val),
      getTemporaryDirectory().then((dir) => _cacheRoot = dir.path),
    ]).then((_) {
      _log.finest("using $_cacheRoot as the root cache directory");
      _initUserParams(_pref.getString(_userKey));
    });
  }

  Future<Isar> _openDb(Directory dir) async {
    const schemas = [DriveInfoSchema, FileMetaSchema];

    final isar = await Isar.open(
      schemas,
      directory: dir.path,
      name: _dbName,
      inspector: false,
    );
    // Database already initialized, no further action required.
    if ((await isar.driveInfos.get(0)) != null) {
      _log.fine("database file already exists");
      return isar;
    }
    _log.finer("no database found locally");

    // Next we need to check if the database has been backed up remotely.
    while (_googleSignIn.currentUser == null) {
      await _googleSignIn.onCurrentUserChanged.first;
    }
    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    final appName = (await PackageInfo.fromPlatform()).appName;
    final dataMineDir = await ensureDriveFolder(api, 'my_data_mine', null);
    final appDir = await ensureDriveFolder(api, appName, dataMineDir.id);

    final driveQuery = "'${appDir.id}' in parents";
    final dbQuery = "name='$_dbName' and $driveQuery";
    final dumpFile = (await api.files.list(q: dbQuery)).files ?? [];
    String dumpFileId = "";
    if (dumpFile.isNotEmpty) {
      dumpFileId = dumpFile[0].id!;
      final isarPath = isar.path!;
      final tmpFilePath = path.join(_cachePath, _dbName);
      final file = await downloadDriveFile(api, dumpFileId, tmpFilePath);
      if (file.lengthSync() > 0) {
        await isar.close(deleteFromDisk: true);
        await file.rename(isarPath);
        _log.fine("downloaded database file from remote store");
        return Isar.open(
          schemas,
          directory: dir.path,
          name: _dbName,
          inspector: false,
        );
      }
    }

    // Most likely a first time install, but also remotely possible it's an
    // upgrade. In the latter case we want to populate the DB with everything
    // currently in the drive folder.
    _log.finer("no database found on remote");
    final driveFiles = (await api.files.list(q: driveQuery)).files ?? [];
    if (dumpFileId == "") {
      final dumpFile = drive.File(name: _dbName, parents: [appDir.id!]);
      final createResp = await api.files.create(dumpFile);
      dumpFileId = createResp.id!;
    }

    await isar.writeTxn(() => isar.clear());
    await isar.writeTxn(() {
      final info = DriveInfo(
        email: _googleSignIn.currentUser!.email,
        folderId: appDir.id!,
        dbDumpId: dumpFileId,
      );
      return isar.driveInfos.put(info);
    });
    await isar.writeTxn(() {
      final fileList = driveFiles
          .where((f) => f.name != _dbName)
          .map((f) => FileMeta(f.name!, driveId: f.id))
          .toList(growable: false);
      return isar.fileMetas.putAll(fileList);
    });
    _log.fine("created a fresh database");

    await _backupDb(isar, api);
    return isar;
  }

  Future<void> signIn() async {
    GoogleSignInAccount? user;
    try {
      user = await _googleSignIn.signInSilently(
          suppressErrors: false, reAuthenticate: true);
    } catch (err) {
      _log.info("silent sign in failed", err);
    }
    if (user == null) {
      await _googleSignIn.signIn();
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
  }

  Future<void> _initUserParams(String? userName) async {
    _cachePath = path.join(_cacheRoot, _prefix, userName ?? "anonymous");
    await Directory(_cachePath).create(recursive: true);
    _log.finer("using $_cachePath as the cache directory");
    if (userName == null) return;

    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    final idKey = "$_prefix:$userName:folderID";
    _folderID = _pref.getString(idKey);
    if (_folderID == null) {
      final appName = (await PackageInfo.fromPlatform()).appName;
      final dataMineDir = await ensureDriveFolder(api, 'my_data_mine', null);
      final appDir = await ensureDriveFolder(api, appName, dataMineDir.id);
      _folderID = appDir.id!;
      _pref.setString(idKey, _folderID!);
    }
    _fileIDs = await readDriveFolder(api, _folderID!);

    _pref.setString(_userKey, userName);
  }

  void _onUserChange(GoogleSignInAccount? user) async {
    if (user == null) {
      _onlineReady = Completer<void>();
    } else if (_onlineReady.isCompleted) {
      _log.warning("unexpected user change while signed in $user");
    } else {
      final isar = await _dbReady;
      final savedUser = (await isar.driveInfos.get(0))!.email;
      if (savedUser == user.email) {
        await _initUserParams(user.email);
        _onlineReady.complete();
      } else {
        final msg = "multiple users unsupported: "
            "signed in with ${user.email}, database configured for $savedUser";
        _onlineReady.completeError(Exception(msg));
      }
    }
  }

  void _watchUploads(Isar isar) async {
    final query = isar.fileMetas.where().uploadPendingEqualTo(true).build();
    final watcher = query.watchLazy().asBroadcastStream();

    while (true) {
      await _uploadPending(isar, query);
      await watcher.first;
      _log.finest("change detected in file list pending upload");
    }
  }

  Future<void> _uploadPending(Isar isar, Query<FileMeta> query) async {
    // Wait for online ready before we run the query to try to catch all
    // files changed while we are in offline mode.
    await _onlineReady.future;
    final pending = await query.findAll();
    if (pending.isEmpty) return;

    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);
    final folderId = (await isar.driveInfos.get(0))!.folderId;

    for (final meta in pending) {
      final local = File(path.join(_cachePath, meta.id));
      if (!(await local.exists())) {
        _log.severe("${meta.localPath} removed before upload to the data mine");
        continue;
      }

      final media = drive.Media(local.openRead(), await local.length());
      if (meta.driveId != null) {
        _log.finer("updating file ${meta.id}");
        await api.files.update(drive.File(), meta.driveId!, uploadMedia: media);
      } else {
        _log.finer("creating new file ${meta.id}");
        final driveFile = drive.File(
          name: meta.id,
          originalFilename: path.basename(meta.localPath!),
          parents: [folderId],
        );
        final resp = await api.files.create(driveFile, uploadMedia: media);
        meta.driveId = resp.id;
      }
      _log.fine("uploaded ${meta.id} with drive ID ${meta.driveId}");
      meta.uploadPending = false;
      await isar.writeTxn(() => isar.fileMetas.put(meta), silent: true);
    }

    await _backupDb(isar, api);
  }

  Future<void> _backupDb(Isar isar, drive.DriveApi api) async {
    final dumpPath = path.join(_cachePath, _dbName);
    final local = File(dumpPath);
    try {
      await local.delete();
    } on PathNotFoundException {
      // file doesn't exist, so copying backup file won't conflict anyway
    }
    await isar.copyToFile(dumpPath);

    final driveId = (await isar.driveInfos.get(0))!.dbDumpId;
    final media = drive.Media(local.openRead(), await local.length());
    await api.files.update(drive.File(), driveId, uploadMedia: media);
    _log.finer("backed up database dump file");
  }

  Future<List<String>> listFiles() async {
    return _fileIDs?.keys.toList() ?? [];
  }

  /// Stores a file to the data mine. If an ID is provided and matches a
  /// previously stored file the contents will be updated. If an ID is not
  /// provided one will be generated automatically from a hash of the file's
  /// contents.
  Future<String> storeFile(File local, {String? id}) async {
    if (id == null) {
      final rawHash = SHA256();
      await for (List<int> chunk in local.openRead()) {
        rawHash.update(chunk);
      }
      id = base64UrlEncode(rawHash.digest());
    }
    // backup the current file to the cache, both to avoid capturing unwanted
    // changes, and to allow the `getFile` method to avoid downloading it.
    await local.copy(path.join(_cachePath, id));

    final isar = await _dbReady;
    var meta = await isar.fileMetas.get(fastHash(id));
    if (meta == null) {
      meta = FileMeta(id, localPath: local.path, uploadPending: true);
    } else {
      meta.localPath = local.path;
      meta.uploadPending = true;
    }
    await isar.writeTxn(() => isar.fileMetas.put(meta!));
    return id;
  }

  Future<File> getFile(String id) async {
    final result = File(path.join(_cachePath, id));
    if (await result.exists()) {
      _log.finer("returning file $id from the cache");
      return result;
    }

    await _onlineReady.future;
    final driveId = _fileIDs![id];
    if (driveId == null) {
      throw FileSystemException("file not found", id);
    }

    _log.fine("downloading file $id as google drive file $driveId");
    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);
    return downloadDriveFile(api, driveId, result.path);
  }
}
