import 'dart:io';

import 'package:logging/logging.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:package_info_plus/package_info_plus.dart';

import 'id_map_cache.dart';

final _log = Logger("datamine_client");

class DriveApi implements Remote {
  final drive.DriveApi _baseApi;
  String _folderId = "";

  String get folderId => _folderId;

  DriveApi(this._baseApi);

  Future<void> initFolder(String? savedId) async {
    if (savedId != null) {
      _folderId = savedId;
      return;
    }

    final paths = [
      "my_data_mine",
      (await PackageInfo.fromPlatform()).appName,
    ];
    String? prevId;
    for (final name in paths) {
      prevId = await _ensureFolder(name, prevId);
    }
    _folderId = prevId!;
  }

  Future<String> _ensureFolder(String name, String? parent) async {
    const folderType = 'application/vnd.google-apps.folder';

    String query = "mimeType='$folderType' and name='$name'";
    if (parent != null) query += " and '$parent' in parents";
    final list = await _baseApi.files.list(q: query);
    final files = list.files ?? [];

    if (files.isEmpty) {
      _log.fine("creating new folder $name with parent $parent");
      final newFolder = await _baseApi.files.create(drive.File(
        name: name,
        mimeType: folderType,
        parents: parent != null ? [parent] : null,
      ));
      return newFolder.id!;
    }

    if (files.length > 1) {
      _log.warning("ambiguous data setup: ${files.length} folders match $name");
    }
    return files[0].id!;
  }

  @override
  Future<Map<String, String>> readFolder() async {
    final query = "'$_folderId' in parents";
    final list = await _baseApi.files.list(q: query);
    return {for (final f in list.files!) f.name!: f.id!};
  }

  Future<drive.File?> _getFileInfo(String fileName) async {
    final query = "name='$fileName' and '$_folderId' in parents";
    final list = await _baseApi.files.list(q: query);
    final files = list.files ?? [];

    if (files.isEmpty) return null;
    if (files.length > 1) {
      _log.warning("ambiguous remote: ${files.length} files match $fileName");
    }
    return files[0];
  }

  Future<File> downloadFile(String fileId, String destination) async {
    final driveFile = await _baseApi.files.get(fileId,
        downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;

    final result = File(destination);
    final sink = result.openWrite();
    await sink.addStream(driveFile.stream);
    await sink.close();
    return result;
  }

  Future<String> uploadFile(String fileName, File contents) async {
    final remote = await _getFileInfo(fileName);
    final media = drive.Media(contents.openRead(), await contents.length());

    if (remote == null) {
      _log.finer("creating new file $fileName");
      final driveFile = drive.File(name: fileName, parents: [_folderId]);
      final resp = await _baseApi.files.create(driveFile, uploadMedia: media);
      return resp.id!;
    }

    final driveId = remote.id!;
    _log.finer("updating file $fileName (drive ID = $driveId)");
    await _baseApi.files.update(drive.File(), driveId, uploadMedia: media);
    return driveId;
  }
}
