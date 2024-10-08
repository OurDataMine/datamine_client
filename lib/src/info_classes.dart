import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

final log = Logger("datamine_client");
final appName = PackageInfo.fromPlatform().then((info) => info.appName);
final deviceName = _getDeviceName();

class UserInfo {
  final String email;
  final String? displayName;
  final String? photoUrl;
  final String? id;
  final String? openIdToken;
  String? photoPath;

  @override
  String toString() => "$displayName <$email>";

  UserInfo(this.email, this.displayName, this.photoUrl, this.id,
      [this.openIdToken, this.photoPath]);
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

  Future<void> cachePhoto(Directory dir) async {
    final url = photoUrl;
    if (url == null) {
      photoPath = null;
      return;
    }

    // Not sure the URL will ever have an extension in it, but if it does
    // go ahead and use it the the filename for the cached image.
    final cacheFile = "$email-avatar${path.extension(url)}";
    final filePath = path.join(dir.path, cacheFile);
    final resp = await http.get(Uri.parse(url));
    await File(filePath).writeAsBytes(resp.bodyBytes);
    photoPath = filePath;
  }
}

Future<String> _getDeviceName() {
  final plugin = DeviceInfoPlugin();
  final possible = [
    plugin.androidInfo.then((info) => info.model),
    plugin.iosInfo.then((info) => info.localizedModel),
    plugin.linuxInfo.then((info) => info.prettyName)
  ].map((f) => f.catchError((_) => ""));

  return Future.wait(possible).then((values) {
    final result = values.where((name) => name != "").first;
    if (result != "") return result;
    return "Unknown";
  });
}

class OwnershipException implements Exception {
  final DeviceInfo currentOwner;
  OwnershipException(this.currentOwner);

  @override
  String toString() =>
      "data mine currently owned by another device (${currentOwner.deviceName})";
}

class DeviceInfo {
  final String deviceId;
  final String deviceName;

  const DeviceInfo(this.deviceId, this.deviceName);
  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        json["deviceId"] ?? "",
        json["device_name"] ?? "",
      );
  Map<String, dynamic> toJson() => {
        "deviceId": deviceId,
        "device_name": deviceName,
      };
}
