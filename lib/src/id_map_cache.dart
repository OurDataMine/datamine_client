import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'info_classes.dart';

final _log = log;

abstract class IDMapRemote {
  Future<Map<String, String>> readFolder();
  Future<String?> findFile(String name);
}

class IDMapCache {
  static const _refreshInt = Duration(days: 1);
  final File _file;
  IDMapRemote? _remote;
  DateTime? _lastSync;
  Map<String, String?> _idMap = {};

  IDMapCache(String filePath) : _file = File(filePath) {
    if (!_file.existsSync()) return;

    try {
      final rawJson = jsonDecode(_file.readAsStringSync());
      _lastSync = rawJson["last_sync"] == null
          ? null
          : DateTime.parse(rawJson["last_sync"] as String);
      _idMap = (rawJson["id_map"] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(key, value as String?),
      ) ??
          {};
    } on FormatException catch (e) {
      _log.severe("Unable to parse cache JSON: $e");
      return;
    }

  }

  void addRemote(IDMapRemote r) {
    _remote = r;
    _refresh();
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

  List<String> listFiles() => _idMap.keys.toList();

  Future<String?> getID(String fileName) async {
    if (!_idMap.containsKey(fileName)) {
      final remoteId = await _remote?.findFile(fileName);
      setID(fileName, remoteId);
      if (remoteId != null) {
        _log.warning("Cache Miss.  Rebuilding the Cache");
        // Found a file that exist, but not in the cache. Rebuild.
        _refresh(force: true);
      } // else, it doesn't actually exist, so our cache is accurate.
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
    final start = DateTime.now();
    // We want to keep all the values that might not have been uploaded to
    // the remote yet, but if it was uploaded and isn't there anymore go
    // ahead and remove it.
    final update = await _remote!.readFolder();
    _idMap
      ..removeWhere((_, value) => value != null)
      ..addAll(update);

    _saveFile();
    final stop = DateTime.now();
    final duration = stop.difference(start);
    final seconds = duration.inMicroseconds/10e6;
    _log.fine("Finished Refresh in ${seconds.toStringAsFixed(3)} seconds");
    return true;
  }

  void _saveFile() {
    _lastSync = DateTime.now();
    final rawJson = jsonEncode({
      "last_sync": _lastSync?.toIso8601String(),
      "id_map": _idMap,
    });
    _file.writeAsString(rawJson);
  }
}
