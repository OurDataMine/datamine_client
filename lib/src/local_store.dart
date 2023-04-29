import 'package:isar/isar.dart';

part 'local_store.g.dart';

@collection
class DriveInfo {
  final Id isarId = 0; // Only supporting one drive account for now
  final String email;
  final String folderId;
  final String dbDumpId;

  DriveInfo({
    required this.email,
    required this.folderId,
    required this.dbDumpId,
  });
}

@collection
class FileMeta {
  final String id;
  Id get isarId => fastHash(id);

  String? localPath;
  String? driveId;

  @Index()
  bool uploadPending;

  FileMeta(this.id, {this.localPath, this.driveId, this.uploadPending = false});
}

/// FNV-1a 64bit hash algorithm optimized for Dart Strings.
/// Copied and slightly modified from https://isar.dev/recipes/string_ids.html
int fastHash(String string) {
  const fnvOffset = 0xcbf29ce484222325;
  const fnvPrime = 0x100000001b3;

  var hash = fnvOffset;
  for (var i = 0; i < string.length; i++) {
    final codeUnit = string.codeUnitAt(i);
    hash ^= codeUnit >> 8;
    hash *= fnvPrime;
    hash ^= codeUnit & 0xFF;
    hash *= fnvPrime;
  }

  return hash;
}
