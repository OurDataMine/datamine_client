import 'dart:io';

import '../info_classes.dart';

export '../info_classes.dart';
export './google_drive.dart';

abstract class Backend {
  Future<UserInfo?> signIn();
  Future<void> signOut();

  Future<File> downloadFile(String fileId, String destination);
  Future<void> uploadFile(String fileName, File contents);
}

class OfflineBackend implements Backend {
  @override
  Future<UserInfo?> signIn() {
    throw UnsupportedError("offline client does not support IO");
  }

  @override
  Future<void> signOut() {
    throw UnsupportedError("offline client does not support IO");
  }

  @override
  Future<File> downloadFile(String fileId, String destination) {
    throw UnsupportedError("offline client does not support IO");
  }

  @override
  Future<void> uploadFile(String fileName, File contents) {
    throw UnsupportedError("offline client does not support IO");
  }
}
