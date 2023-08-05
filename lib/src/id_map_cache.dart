import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;

class UserInfo {
  final String email;
  final String? displayName;
  final String? photoUrl;
  String? photoPath;

  @override
  String toString() => "$displayName <$email>";

  UserInfo(this.email, this.displayName, this.photoUrl, [this.photoPath]);
  factory UserInfo.fromJson(Map<String, dynamic> json) => UserInfo(
        json["email"],
        json["displayName"],
        json["photoUrl"],
        json["photoPath"],
      );
  Map<String, dynamic> toJson() => {
        "email": email,
        "displayName": displayName,
        "photoUrl": photoUrl,
        "photoPath": photoPath,
      };
}

abstract class Remote {
  Future<Map<String, String>> readFolder();
}

class IDMapCache {
  static const _refreshInt = Duration(days: 1);
  final File _file;
  Remote? _remote;
  UserInfo? _user;
  DateTime? _lastSync;
  Map<String, String?> _idMap = {};

  IDMapCache(String filePath) : _file = File(filePath) {
    if (!_file.existsSync()) return;

    final rawJson = jsonDecode(_file.readAsStringSync());
    _user = rawJson["user"] == null
        ? null
        : UserInfo.fromJson(rawJson["user"] as Map<String, dynamic>);
    _lastSync = rawJson["last_sync"] == null
        ? null
        : DateTime.parse(rawJson["last_sync"] as String);
    _idMap = (rawJson["id_map"] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, value as String?),
        ) ??
        {};
  }

  void addRemote(UserInfo user, Remote r) {
    final photoUrl = user.photoUrl;
    if (photoUrl != null) {
      if (_user?.photoPath != null) {
        user.photoPath = _user!.photoPath;
      } else {
        // Not sure the URL will ever have an extension in it, but if it does
        // go ahead and use it the the filename for the cached image.
        final cacheFile = "${user.email}-avatar${path.extension(photoUrl)}";
        user.photoPath = path.join(path.dirname(_file.path), cacheFile);
      }
      http.get(Uri.parse(photoUrl)).then((response) {
        final imgFile = File(user.photoPath!);
        imgFile.writeAsBytesSync(response.bodyBytes);
      });
    }

    final userChanged = user != _user;
    _user = user;
    _remote = r;
    // This logic to make sure we save changes to the user if the user changed
    // is unlikely to be necessary in real use cases, but it's helpful for me
    // while testing
    _refresh().then((bool saved) {
      if (!saved && userChanged) _saveFile();
    });
  }

  /// mergeOld is intended to be use only when a previously unauthenticated
  /// user logs in for the first time. We need to preserve the names for all
  /// the files stored localy until they can be uploaded.
  void mergeOld(IDMapCache old) {
    for (final key in old._idMap.keys) {
      if (!_idMap.containsKey(key)) {
        _idMap[key] = old._idMap[key];
      }
    }
    _saveFile();

    if (old._file.existsSync()) {
      old._file.deleteSync();
    }
  }

  UserInfo? get user => _user;

  List<String> listFiles() => _idMap.keys.toList();

  Future<String?> getID(String fileName) async {
    if (!_idMap.containsKey(fileName)) {
      await _refresh(force: true);
    }
    return _idMap[fileName];
  }

  void setID(String fileName, String? remoteId) {
    if (remoteId == null && _idMap.containsKey(fileName)) return;
    if (remoteId != null && _idMap[fileName] == remoteId) return;

    _idMap[fileName] = remoteId;
    _saveFile();
  }

  Future<bool> _refresh({bool force = false}) async {
    if (_remote == null) return false;
    if (!force && _lastSync != null) {
      if (DateTime.now().difference(_lastSync!) < _refreshInt) {
        return false;
      }
    }

    // We want to keep all the values that might not have been uploaded to
    // the remote yet, but if it was uploaded and isn't there anymore go
    // ahead and remove it.
    final update = await _remote!.readFolder();
    _idMap
      ..removeWhere((_, value) => value != null)
      ..addAll(update);

    _lastSync = DateTime.now();
    _saveFile();
    return true;
  }

  void _saveFile() {
    final rawJson = jsonEncode({
      "user": _user?.toJson(),
      "last_sync": _lastSync?.toIso8601String(),
      "id_map": _idMap,
    });
    _file.writeAsString(rawJson);
  }
}
