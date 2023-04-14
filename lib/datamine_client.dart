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
  final String email;
  final String? displayName;
  final String? photoUrl;

  @override
  String toString() => "$displayName <$email>";

  const UserInfo(this.email, this.displayName, this.photoUrl);
}

/// A client to interact with a DataMine's storage.
class DatamineClient {
  static const _dbName = "data_mine_client";

  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive.file',
  ]);
  late final Future<Isar> _dbReady = _openDb();
  Completer<void> _onlineReady = Completer<void>();
  late final String _cachePath;

  final _userInfoCtrl = StreamController<UserInfo?>.broadcast();
  UserInfo? get currentUser {
    final gUser = _googleSignIn.currentUser;
    if (gUser == null) {
      return null;
    }
    return UserInfo(gUser.email, gUser.displayName, gUser.photoUrl);
  }

  DatamineClient() {
    _dbReady.then(_watchUploads);
    _googleSignIn.onCurrentUserChanged.listen(_onUserChange);

    getTemporaryDirectory().then((dir) {
      _cachePath = dir.path;
      _log.finest("using $_cachePath as the download directory");
    });
  }

  Future<Isar> _openDb() async {
    const schemas = [DriveInfoSchema, FileMetaSchema];

    final isar = await Isar.open(schemas, name: _dbName);
    final dbPath = isar.path!;
    // Database already initialized, no further action required.
    if ((await isar.driveInfos.get(0)) != null) {
      _log.fine("database file already exists");
      return isar;
    }
    _log.finer("no database found locally");

    // Next we need to check if the database has been backed up remotely.
    await _onlineReady.future;
    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);

    final appName = (await PackageInfo.fromPlatform()).appName;
    final dataMineDir = await _ensureFolder(api, 'my_data_mine', null);
    final appDir = await _ensureFolder(api, appName, dataMineDir.id);

    final driveQuery = "'${appDir.id}' in parents";
    final dbQuery = "name='$_dbName' and $driveQuery";
    final dumpFile = (await api.files.list(q: dbQuery)).files ?? [];
    String dumpFileId = "";
    if (dumpFile.isNotEmpty) {
      dumpFileId = dumpFile[0].id!;
      final dbMedia = await api.files.get(dumpFileId,
          downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;

      // Protect against the possibility of the first backup failing after
      // the file was created.
      if (dbMedia.length! > 0) {
        isar.close(deleteFromDisk: true);
        final local = File(dbPath);
        final sink = local.openWrite();
        await sink.addStream(dbMedia.stream);
        await sink.close();
        _log.fine("downloaded database file from remote store");
        return Isar.open(schemas, name: _dbName);
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

    _backupDb(isar, api);
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
    await _googleSignIn.disconnect();
  }

  void _onUserChange(GoogleSignInAccount? user) async {
    if (user == null) {
      _onlineReady = Completer<void>();
      _userInfoCtrl.add(null);
    } else {
      _userInfoCtrl.add(UserInfo(user.email, user.displayName, user.photoUrl));
      if (!_onlineReady.isCompleted) {
        _onlineReady.complete();
      } else {
        _log.warning("unexpected user change while signed in $user");
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
      final local = File(meta.localPath!);
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

    _backupDb(isar, api);
  }

  Future<void> _backupDb(Isar isar, drive.DriveApi api) async {
    final dumpPath = path.join(_cachePath, _dbName);
    final local = File(dumpPath);
    await local.delete();
    await isar.copyToFile(dumpPath);

    final driveId = (await isar.driveInfos.get(0))!.dbDumpId;
    final media = drive.Media(local.openRead(), await local.length());
    await api.files.update(drive.File(), driveId, uploadMedia: media);
    _log.finer("backed up database dump file");
  }

  Future<List<String>> listFiles() async {
    final isar = await _dbReady;
    return isar.fileMetas.where().idProperty().findAll();
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

  Future<File> getFile(String fileId) async {
    final result = File(path.join(_cachePath, fileId));
    if (await result.exists()) {
      _log.fine("returning file $fileId from the cache");
      return result;
    }

    final isar = await _dbReady;
    final meta = await isar.fileMetas.get(fastHash(fileId));
    if (meta == null) {
      throw FileSystemException("file not found", fileId);
    } else if (meta.driveId == null) {
      throw FileSystemException("file storage not complete", fileId);
    }

    await _onlineReady.future;
    _log.fine("downloading file $fileId as google drive file ${meta.driveId}");

    final client = await _googleSignIn.authenticatedClient();
    final api = drive.DriveApi(client!);
    final driveFile = await api.files.get(meta.driveId!,
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
