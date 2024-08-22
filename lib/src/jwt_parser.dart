import 'dart:convert';

Map<String, dynamic> parseJwt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) {
    throw Exception('invalid token');
  }

  String normalizedSource = base64Url.normalize(parts[1]);
  final jsonStr = utf8.decode(base64Url.decode(normalizedSource));
  final payloadMap = json.decode(jsonStr);
  if (payloadMap is! Map<String, dynamic>) {
    throw Exception('invalid payload');
  }

  return payloadMap;
}
