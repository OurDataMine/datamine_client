import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hash/hash.dart';
import 'package:path/path.dart' as path;

import 'package:path_provider/path_provider.dart';

import 'src/backends/backends.dart';
import 'src/simple_store.dart';

export 'src/info_classes.dart' show OwnershipException, DeviceInfo, UserInfo;

final _log = log;

/// A client to interact with a DataMine's storage.
class DatamineClient {
  static const _prefix = "_dmc";
  static const _ownerFileName = "${_prefix}_primary_device.json";

  final _store = SimpleStore();
  final _ready = Completer<void>();
  final _userStream = StreamController<UserInfo?>.broadcast();
  late final String _cacheRoot, _dataRoot;
  late Directory _cacheDir, _dataDir;
  late IDMapCache _fileIDs;

  Backend _backend = OfflineBackend();

  /// User info for the account used to sign in.
  Future<UserInfo?> get currentUser =>
      _ready.future.then((_) => _store.currentUser);

  /// True if we haven't signed in this session to start interacting with the
  /// remote.
  bool get offline => _backend is OfflineBackend;

  /// Subscribe to this stream to be notified when the current user changes.
  late final Stream<UserInfo?> onUserChanged = _userStream.stream;

  DatamineClient() {
    Future.wait([
      _store.ready,
      getTemporaryDirectory()
          .then((dir) => _cacheRoot = path.join(dir.path, _prefix)),
      getApplicationSupportDirectory()
          .then((dir) => _dataRoot = path.join(dir.path, _prefix)),
    ]).then((_) {
      _log.finest("using $_dataRoot as the root data directory");
      _log.finest("using $_cacheRoot as the root cache directory");
      return _initLocalStore(_store.currentUser);
    }).then(_ready.complete, onError: _ready.completeError);
  }

  Future<UserInfo?> refreshAuth() => _backend.refresh();

  /// If signIn returns a non-null DeviceInfo that represents the device that
  /// currently "owns" the Data Mine. This device will not be able to write any
  /// files to the Data Mine unless signIn is called again with `force: true`.
  Future<void> signIn({bool force = false}) async {
    if (!offline) throw Exception("cannot sign in multiple times");

    _backend = GDriveBackend();
    final user = await _backend.signIn();
    await _setUser(user);
    _userStream.sink.add(user);
    _backend.addIDCache(_fileIDs);

    await aquireOwnership(force: force);
  }

  Future<void> aquireOwnership({bool force=false}) async {
    final curOwner = await _checkPrimDevice();
    if (curOwner?.deviceId != _store.deviceId) {
      if (curOwner == null || force) {
        _claimPrimDevice();
      } else {
        throw OwnershipException(curOwner);
      }
    }
  }

  Future<void> signOut() {
    final prev = _backend;
    _backend = OfflineBackend();
    _userStream.sink.add(null);
    return prev.signOut();
  }

  Future<DeviceInfo?> _checkPrimDevice() async {
    final filePath = path.join(_cacheDir.path, "primary_device.json");
    final File file;
    try {
      file = await _backend.downloadFile(_ownerFileName, filePath);
    } on FileSystemException catch (_) {
      return null;
    }
    final rawJson = jsonDecode(await file.readAsString());
    return DeviceInfo.fromJson(rawJson);
  }

  Future<void> _claimPrimDevice() async {
    final info = DeviceInfo(_store.deviceId, await deviceName);
    final file = File(path.join(_cacheDir.path, "primary_device.json"));
    await file.writeAsString(jsonEncode(info.toJson()));
    await _backend.uploadFile(_ownerFileName, file);
  }

  void _initLocalStore(UserInfo? user) {
    final userName = user?.email;
    _dataDir = Directory(path.join(_dataRoot, userName ?? "anonymous"))
      ..create(recursive: true);
    _log.finer("using ${_dataDir.path} as the data directory");

    final idFile = path.join(_dataRoot, '${userName ?? "anonymous"}-ids.json');
    _fileIDs = IDMapCache(idFile);

    if (userName == null) {
      _cacheDir = _dataDir;
    } else {
      _cacheDir = Directory(path.join(_cacheRoot, userName))
        ..create(recursive: true);
    }
    _log.finer("using ${_cacheDir.path} as the cache directory");
  }

  Future<void> _setUser(UserInfo? user) async {
    // I can't see this await really being necessary, but just be safe. In
    // theory signIn could be before all the constructor's awaits are finished.
    await _ready.future;
    final List<Future<void>> pending = [];

    // If we were in anonymous mode previously we need to move all the files
    // into the new user's directory for upload, and copy them to the cache.
    final prevDataDir = _dataDir, prevFileIDs = _fileIDs;
    _initLocalStore(user);
    if (user != null && prevDataDir.path.endsWith("anonymous")) {
      handleFile(file) async {
        final origFile = File(file.absolute.path);
        await origFile.copy(path.join(_cacheDir.path, file.path));
        await origFile.rename(path.join(_dataDir.path, file.path));
      }

      pending.add(prevDataDir.list().toList().then((files) {
        return Future.wait(files.map(handleFile));
      }).then((_) {
        _fileIDs.mergeOld(prevFileIDs);
        return prevDataDir.delete().then((_) {});
      }));
    }

    if (user != null) {
      pending.add(user.cachePhoto(_cacheDir));
    }
    await Future.wait(pending);
    _store.currentUser = user;
  }

  Future<int> bgUpload(String taskId, {int maxUploads = 1}) async {
    _log.finest("background upload task $taskId started");
    final fileStream = _dataDir.listSync();

    final count = fileStream.length;
    _log.info("Files to upload: $count");
    fileStream.take(maxUploads).forEach((entity) async {
      _uploadFile(entity.path).onError((error, stackTrace) =>
          _log.warning("Unable to upload file: $error"));
    });

    return _dataDir.listSync().length;
  }

  Future<void> _uploadFile(String filePath) async {
    final fileName = path.basename(filePath);

    final curOwner = await _checkPrimDevice();
    if (curOwner?.deviceId != _store.deviceId) {
      _log.warning("uploading $fileName skipped because ownership conflict");
      return;
    }

    _log.fine("starting upload $fileName");
    final local = File(filePath);
    await _backend.uploadFile(fileName, local);
    await local.delete();
    _log.info("finished uploading $fileName");
  }

  Future<List<String>> listFiles() async {
    await _ready.future;
    return _fileIDs
        .listFiles()
        .where((name) => _prefix.matchAsPrefix(name) == null)
        .toList();
  }

  /// Stores a file to the data mine. If an ID is provided and matches a
  /// previously stored file the contents will be updated. If an ID is not
  /// provided one will be generated automatically from a hash of the file's
  /// contents.
  Future<String> storeFile(File local, {String? id}) async {
    await _ready.future;
    if (id == null) {
      final rawHash = SHA256();
      await for (List<int> chunk in local.openRead()) {
        rawHash.update(chunk);
      }
      id = base64UrlEncode(rawHash.digest());
    }
    if (_prefix.matchAsPrefix(id) != null) {
      throw FormatException("invalid file ID $id: may not start with $_prefix");
    }

    // Save to the data directory to mark it as something that needs to be
    // synced to the cloud still, and save it to the cache as well if we
    // are operating in authenticated mode and have a real cache directory
    final copies = [local.copy(path.join(_dataDir.path, id))];
    if (_cacheDir != _dataDir) {
      copies.add(local.copy(path.join(_cacheDir.path, id)));
    }
    await Future.wait(copies);
    _fileIDs.setID(id, null);

    return id;
  }

  Future<File> getFile(String id) async {
    if (_prefix.matchAsPrefix(id) != null) {
      throw FormatException("invalid file ID $id: may not start with $_prefix");
    }

    await _ready.future;
    final result = File(path.join(_cacheDir.path, id));
    if (await result.exists()) {
      _log.finer("returning file $id from the cache");
      return result;
    }

    return _backend.downloadFile(id, result.path);
  }
}
