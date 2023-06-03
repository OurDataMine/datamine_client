import 'dart:io';

import 'package:logging/logging.dart';
import 'package:googleapis/drive/v3.dart' as drive;

final _log = Logger("datamine_client");

Future<drive.File> ensureDriveFolder(
  drive.DriveApi api,
  String name,
  String? parent,
) async {
  const folderType = 'application/vnd.google-apps.folder';

  String query = "mimeType='$folderType' and name='$name'";
  if (parent != null) query += " and '$parent' in parents";
  final list = await api.files.list(q: query);
  final files = list.files ?? [];

  if (files.isEmpty) {
    _log.fine("creating new folder $name with parent $parent");
    return api.files.create(drive.File(
      name: name,
      mimeType: folderType,
      parents: parent != null ? [parent] : null,
    ));
  }

  if (files.length > 1) {
    _log.warning("ambiguous data setup: ${files.length} folders match $name");
  }
  return files[0];
}

Future<Map<String, String>> readDriveFolder(
  drive.DriveApi api,
  String name,
) async {
  final query = "'$name' in parents";
  final list = await api.files.list(q: query);
  return {for (final f in list.files!) f.name!: f.id!};
}

Future<File> downloadDriveFile(
  drive.DriveApi api,
  String fileId,
  String destination,
) async {
  final driveFile = await api.files.get(fileId,
      downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;

  final result = File(destination);
  final sink = result.openWrite();
  await sink.addStream(driveFile.stream);
  await sink.close();
  return result;
}
