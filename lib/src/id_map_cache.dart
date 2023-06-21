import 'dart:async';
import 'dart:convert';
import 'dart:io';

abstract class Remote {
  Future<Map<String, String>> readFolder();
}

class IDMapCache {
  static const _refreshInt = Duration(days: 1);
  final File _file;
  Remote? _remote;
  DateTime? _lastSync;
  Map<String, String?> _idMap = {};

  IDMapCache(String filePath) : _file = File(filePath) {
    if (!_file.existsSync()) return;
    final rawJson = jsonDecode(_file.readAsStringSync());
    _lastSync = rawJson["last_sync"] == null
        ? null
        : DateTime.parse(rawJson["last_sync"] as String);
    _idMap = (rawJson["id_map"] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, value as String?),
        ) ??
        {};
  }

  void addRemote(Remote r) {
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
    old._file.deleteSync();
  }

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

  Future<void> _refresh({bool force = false}) async {
    if (_remote == null) return;
    if (!force && _lastSync != null) {
      if (DateTime.now().difference(_lastSync!) < _refreshInt) {
        return;
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
  }

  void _saveFile() {
    final rawJson = jsonEncode({
      "last_sync": _lastSync?.toIso8601String(),
      "id_map": _idMap,
    });
    _file.writeAsString(rawJson);
  }
}
