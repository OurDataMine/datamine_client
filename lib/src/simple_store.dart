import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import './info_classes.dart';

class SimpleStore {
  static const _prefix = "_dmc";

  static const _uuid = Uuid();
  late final SharedPreferences _sharedPref;
  late final ready =
      SharedPreferences.getInstance().then((val) => _sharedPref = val);

  String get deviceId {
    const key = "$_prefix:deviceId";
    var value = _sharedPref.getString(key);
    if (value != null) return value;

    value = _uuid.v4();
    _sharedPref.setString(key, value);
    return value;
  }

  static const _userKey = "$_prefix:current_user";
  UserInfo? get currentUser {
    final curEmail = _sharedPref.getString(_userKey);
    if (curEmail == null) return null;

    final rawJson = _sharedPref.getString("$_prefix:$curEmail:user_info");
    if (rawJson == null) return UserInfo(curEmail, "", null, "");
    return UserInfo.fromJson(jsonDecode(rawJson));
  }

  set currentUser(UserInfo? value) {
    if (value == null) {
      _sharedPref.remove(_userKey);
    } else {
      _sharedPref.setString(_userKey, value.email);
      final rawJson = jsonEncode(value.toJson());
      _sharedPref.setString("$_prefix:${value.email}:user_info", rawJson);
    }
  }
}
