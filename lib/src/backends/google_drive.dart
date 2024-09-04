import 'dart:async';
import 'dart:io';

import 'package:datamine_client/src/jwt_parser.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:synchronized/synchronized.dart';

import './backends.dart';

class GDriveBackend implements Backend, IDMapRemote {
  final _googleSignIn = GoogleSignIn(scopes: [
    'profile',
    'https://www.googleapis.com/auth/drive.file',
    "https://www.googleapis.com/auth/drive.appdata",
  ]);
  Completer<drive.DriveApi> _ready = Completer();
  Completer<IDMapCache> _idCache = Completer();
  final loginLock = Lock() ;
  DateTime expiration = DateTime.fromMillisecondsSinceEpoch(0);
  int retries = 0;

  GDriveBackend() {
    _googleSignIn.onCurrentUserChanged.listen(_onUserChange);
  }

  Future<drive.DriveApi> refreshIfNeeded() async {
    if (expiration.isAfter(DateTime.now())) {
      return _ready.future;
    }
    await refresh();
    return await _ready.future;
  }

  @override
  Future<UserInfo?> refresh() async {
    log.info("Refreshing User credentials.");
    if(retries >= 3) {
      log.severe("Google Login retries exceeded.  Not trying again.");
      return null;
    }
    _ready = Completer();
    try {
      final user = await _googleSignIn.signInSilently(
          suppressErrors: false, reAuthenticate: true);
      retries = 0;
      return _convertUser(user);
    } catch (err) {
      log.severe("Unable to refresh credentials.");
      retries++;
      return null;
    }
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

    await loginLock.synchronized(() async {
      if (_ready.isCompleted) {
        // Another thread must have completed login while we were waiting.
        log.info("Already logged in. Not retrying");
        return;
      }

      try {
        final client = await _googleSignIn.authenticatedClient();
        final api = drive.DriveApi(client!);
        log.info("Successfully logged in to Google");
        _ready.complete(api);
      } on Exception catch (ex) {
        log.severe("Network comms with Google had an issue: $ex");
      }
    });
  }

  @override
  Future<Map<String, String>> readFolder() async {
    const orderBy = "createdTime desc";
    final api = await refreshIfNeeded();

    final Map<String, String> result = {};
    String? nextPage;
    do {
      final list = await api.files.list(
        // q: query,
        orderBy: orderBy,
        pageToken: nextPage,
      );
      result.addAll({for (final f in list.files!) f.name!: f.id!});
      nextPage = list.nextPageToken;
    } while (nextPage != null);

    do {
      final list = await api.files.list(
        spaces: "appDataFolder",
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
    final api = await refreshIfNeeded();
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
    final api = await refreshIfNeeded();
    final media = drive.Media(contents.openRead(), await contents.length());
    final drive.File resp;

    String? remoteId = await idCache.getID(fileName);
    remoteId ??= (await _getFileInfo(api, fileName))?.id;
    if (remoteId == null) {
      log.finer("creating new file $fileName");
      final driveFile = drive.File(name: fileName, parents: ['appDataFolder']);
      resp = await api.files.create(driveFile, uploadMedia: media);
      log.finer("Uploaded file $fileName to ${resp.id}");
    } else {
      final driveFile = drive.File(name: fileName);
      log.finer("updating file $fileName (drive ID = $remoteId)");
      resp = await api.files.update(driveFile, remoteId, uploadMedia: media);
    }
    idCache.setID(fileName, resp.id);
  }

  Future<UserInfo?> _convertUser(GoogleSignInAccount? gUser) async {
    if (gUser == null) return null;
    final idToken = (await gUser.authentication).idToken;
    if (idToken != null) {
      final payload = parseJwt(idToken);
      int ts = payload['exp'];
      expiration = DateTime.fromMillisecondsSinceEpoch(1000 * ts);
      log.info("Login will expire at $expiration");
    }
    return UserInfo(gUser.email, gUser.displayName, gUser.photoUrl, gUser.id, idToken);
  }

}

Future<drive.File?> _getFileInfo(
  drive.DriveApi api,
  String name, {
  String? mimeType,
}) async {
  String query = "name='$name'";
  if (mimeType != null) query += " and mimeType='$mimeType'";

  final list = await api.files.list(spaces: "appDataFolder", q: query);
  final files = list.files ?? [];

  if (files.isEmpty) return null;
  if (files.length > 1) {
    log.warning("ambiguous remote: ${files.length} files match $name");
  }
  return files[0];
}
