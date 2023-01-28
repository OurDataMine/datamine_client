import 'package:flutter_test/flutter_test.dart';

import 'package:datamine_client/datamine_client.dart';

void main() {
  test('adds one to input values', () {
    final client = DatamineClient();
    expect(client.signIn(), "User Name");
    client.signOut();
  });
}
