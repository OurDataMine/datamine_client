import 'dart:io';

import 'package:logging/logging.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:package_info_plus/package_info_plus.dart';

import 'id_map_cache.dart';

final _log = Logger("datamine_client");

class DriveApi implements Remote {
  final drive.DriveApi _baseApi;
  late final Future<String> _folderId;

  DriveApi(this._baseApi) {
    _folderId = PackageInfo.fromPlatform().then((info) async {
      final paths = ["my_data_mine", info.appName];
      String? prevId;
      for (final name in paths) {
        prevId = await _ensureFolder(name, prevId);
      }
      return prevId!;
    });
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
    const orderBy = "createdTime desc";
    final query = "'${await _folderId}' in parents";

    final Map<String, String> result = {};
    String? nextPage;
    do {
      final list = await _baseApi.files.list(
        q: query,
        orderBy: orderBy,
        pageToken: nextPage,
      );
      result.addAll({for (final f in list.files!) f.name!: f.id!});
      nextPage = list.nextPageToken;
    } while (nextPage != null);

    return result;
  }

  Future<drive.File?> _getFileInfo(String fileName, String parent) async {
    final query = "name='$fileName' and '$parent' in parents";
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
    final parent = await _folderId;
    final remote = await _getFileInfo(fileName, parent);
    final media = drive.Media(contents.openRead(), await contents.length());

    if (remote == null) {
      _log.finer("creating new file $fileName");
      final driveFile = drive.File(name: fileName, parents: [parent]);
      final resp = await _baseApi.files.create(driveFile, uploadMedia: media);
      return resp.id!;
    }

    final driveId = remote.id!;
    _log.finer("updating file $fileName (drive ID = $driveId)");
    await _baseApi.files.update(drive.File(), driveId, uploadMedia: media);
    return driveId;
  }
}
