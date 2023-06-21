import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hash/hash.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/drive_helpers.dart';
import 'src/id_map_cache.dart';

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

  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive.file',
  ]);
  late final SharedPreferences _pref;
  late final String _cacheRoot, _dataRoot;
  late Directory _cacheDir, _dataDir;
  late IDMapCache _fileIDs;

  var _onlineReady = Completer<DriveApi>();
  StreamSubscription<FileSystemEvent>? _dataWatch;

  /// User info for the account used to sign in.
  UserInfo? get currentUser => UserInfo._fromGoogle(_googleSignIn.currentUser);

  /// Subscribe to this stream to be notified when the current user changes.
  late final Stream<UserInfo?> onUserChanged =
      _googleSignIn.onCurrentUserChanged.map(UserInfo._fromGoogle);

  DatamineClient() {
    _googleSignIn.onCurrentUserChanged.listen(_onUserChange);

    Future.wait([
      SharedPreferences.getInstance().then((val) => _pref = val),
      getTemporaryDirectory()
          .then((dir) => _cacheRoot = path.join(dir.path, _prefix)),
      getApplicationSupportDirectory()
          .then((dir) => _dataRoot = path.join(dir.path, _prefix)),
    ]).then((_) {
      _log.finest("using $_dataRoot as the root data directory");
      _log.finest("using $_cacheRoot as the root cache directory");
      _initLocalStore(_pref.getString(_userKey));
    });
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

  Future<void> _initLocalStore(String? userName) async {
    _dataDir = Directory(path.join(_dataRoot, userName ?? "anonymous"));
    _dataDir.create(recursive: true);
    _log.finer("using ${_dataDir.path} as the data directory");

    final idFile = path.join(_dataRoot, '${userName ?? "anonymous"}-ids.json');
    _fileIDs = IDMapCache(idFile);

    if (userName == null) {
      _cacheDir = _dataDir;
    } else {
      _cacheDir = Directory(path.join(_cacheRoot, userName));
      _cacheDir.create(recursive: true);
    }
    _log.finer("using ${_cacheDir.path} as the cache directory");
  }

  Future<void> _setUser(String userName, DriveApi api) async {
    // If we were in anonymous mode previously we need to move all the files
    // into the new user's directory for upload, and copy them to the cache.
    final prevDataDir = _dataDir;
    final prevFileIDs = _fileIDs;
    _initLocalStore(userName);
    if (prevDataDir.path.endsWith("anonymous")) {
      await for (final file in prevDataDir.list()) {
        final origFile = File(file.absolute.path);
        await origFile.copy(path.join(_cacheDir.path, file.path));
        await origFile.rename(path.join(_dataDir.path, file.path));
      }
      await prevDataDir.delete();
      _fileIDs.mergeOld(prevFileIDs);
    }

    final idKey = "$_prefix:$userName:folderId";
    await api.initFolder(_pref.getString(idKey));
    _pref.setString(idKey, api.folderId);
    _fileIDs.addRemote(api);

    _pref.setString(_userKey, userName);
    _dataDir.list().listen((event) {
      _uploadFile(event.path);
    });
    _dataWatch = _dataDir.watch(events: FileSystemEvent.create).listen((event) {
      _uploadFile(event.path);
    });
  }

  void _onUserChange(GoogleSignInAccount? user) async {
    if (user == null) {
      _onlineReady = Completer<DriveApi>();
      _dataWatch?.cancel();
      _dataWatch = null;
    } else if (_onlineReady.isCompleted) {
      _log.warning("unexpected user change while signed in $user");
    } else {
      final client = await _googleSignIn.authenticatedClient();
      final api = DriveApi(drive.DriveApi(client!));
      await _setUser(user.email, api);
      _onlineReady.complete(api);
    }
  }

  Future<void> _uploadFile(String filePath) async {
    final api = await _onlineReady.future;
    final fileName = path.basename(filePath);
    final local = File(path.join(_dataDir.path, filePath));

    final remoteId = await api.uploadFile(fileName, local);
    _fileIDs.setID(fileName, remoteId);
    await local.delete();
  }

  List<String> listFiles() => _fileIDs.listFiles();

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

    // Save to the data directory to mark it as something that needs to be
    // synced to the cloud still, and save it to the cache as well if we
    // are operating in authenticated mode and have a real cache directory
    final copies = [local.copy(path.join(_dataDir.path, id))];
    if (_cacheDir != _dataDir) {
      copies.add(local.copy(path.join(_cacheDir.path, id)));
    }
    await Future.wait(copies);

    return id;
  }

  Future<File> getFile(String id) async {
    final result = File(path.join(_cacheDir.path, id));
    if (await result.exists()) {
      _log.finer("returning file $id from the cache");
      return result;
    }

    final api = await _onlineReady.future;
    final driveId = await _fileIDs.getID(id);
    if (driveId == null) {
      throw FileSystemException("file not found", id);
    }

    _log.fine("downloading file $id as google drive file $driveId");
    return api.downloadFile(driveId, result.path);
  }
}
