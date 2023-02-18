import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'datamine_client_test.mocks.dart';
import 'package:datamine_client/datamine_client.dart';

@GenerateMocks(<Type>[GoogleSignInPlatform])
void main() {
  late MockGoogleSignInPlatform mockPlatform;
  final defaultUser = GoogleSignInUserData(
    email: 'john.doe@gmail.com',
    id: '8162538176523816253123',
    photoUrl: 'https://lh5.googleusercontent.com/photo.jpg',
    displayName: 'John Doe',
    serverAuthCode: '789',
  );

  setUp(() {
    mockPlatform = MockGoogleSignInPlatform();
    when(mockPlatform.isMock).thenReturn(true);
    when(mockPlatform.signIn()).thenAnswer((Invocation _) async => defaultUser);
    when(mockPlatform.signInSilently())
        .thenAnswer((Invocation _) async => defaultUser);

    GoogleSignInPlatform.instance = mockPlatform;
  });

  test('state changes on sign out', () async {
    final client = DatamineClient();
    await client.signIn();
    expect(client.currentUser?.displayName, defaultUser.displayName);
    expect(client.currentUser?.photoUrl, defaultUser.photoUrl);

    await client.signOut();
    expect(client.currentUser, null);
  });

  test('falls back after failed silent sign in', () async {
    when(mockPlatform.signInSilently()).thenThrow(Exception('Silent fails'));
    final client = DatamineClient();
    await client.signIn();

    verify(mockPlatform.signInSilently());
    verify(mockPlatform.signIn());
  });
}
