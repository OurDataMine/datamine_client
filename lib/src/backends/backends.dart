import 'dart:io';

import '../info_classes.dart';
import '../id_map_cache.dart';

export '../info_classes.dart';
export '../id_map_cache.dart';
export './google_drive.dart';

abstract class Backend {
  Future<UserInfo?> signIn();
  Future<UserInfo?> refresh();
  Future<void> signOut();
  void addIDCache(IDMapCache cache);

  Future<File> downloadFile(String fileId, String destination);
  Future<void> uploadFile(String fileName, File contents);
}

class OfflineBackend implements Backend {
  @override
  Future<UserInfo?> signIn() => Future.value(null);

  @override
  Future<UserInfo?> refresh() => Future.value(null);

  @override
  Future<void> signOut() => Future.value();

  @override
  void addIDCache(_) {}

  @override
  Future<File> downloadFile(String fileId, String destination) {
    throw UnsupportedError("offline client does not support IO");
  }

  @override
  Future<void> uploadFile(String fileName, File contents) {
    throw UnsupportedError("offline client does not support IO");
  }
}
