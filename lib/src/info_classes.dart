import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';

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

Future<String> getDeviceName() {
  final plugin = DeviceInfoPlugin();
  final possible = [
    plugin.androidInfo.then((info) => info.product),
    plugin.iosInfo.then((info) => info.localizedModel),
  ].map((f) => f.catchError((_) => ""));

  return Future.wait(possible).then((values) {
    final result = values.where((name) => name != "").first;
    if (result != "") return result;
    return "Uknown";
  });
}

class DeviceInfo {
  final String fingerprint;
  final String displayName;

  const DeviceInfo(this.fingerprint, this.displayName);
  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        json["fingerprint"],
        json["display_name"],
      );
  Map<String, dynamic> toJson() => {
        "fingerprint": fingerprint,
        "display_name": displayName,
      };
}
