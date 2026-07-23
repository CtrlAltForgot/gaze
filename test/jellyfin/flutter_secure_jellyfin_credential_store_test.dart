import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/flutter_secure_jellyfin_credential_store.dart';
import 'package:gaze/jellyfin/jellyfin_credential_store.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('creates one stable installation device ID', () async {
    const store = FlutterSecureJellyfinCredentialStore();

    final first = await store.getOrCreateDeviceId();
    final second = await store.getOrCreateDeviceId();

    expect(first, hasLength(32));
    expect(second, first);
  });

  test('writes, reads, and deletes the saved connection', () async {
    const store = FlutterSecureJellyfinCredentialStore();
    const connection = SavedJellyfinConnection(
      serverAddress: 'http://music.local:8096',
      accessToken: 'test-token',
      userId: 'user-id',
      userName: 'listener',
      serverId: 'server-id',
      serverName: 'Music Server',
      serverVersion: '10.11.0',
    );

    expect(await store.readConnection(), isNull);
    await store.writeConnection(connection);
    await store.writeProfile(
      const SavedJellyfinProfile(
        serverAddress: 'http://music.local:8096',
        userName: 'listener',
      ),
    );
    final restored = await store.readConnection();
    expect(restored?.serverAddress, connection.serverAddress);
    expect(restored?.accessToken, connection.accessToken);
    expect(restored?.userId, connection.userId);
    expect(restored?.userName, connection.userName);
    expect(restored?.serverId, connection.serverId);
    expect(restored?.serverName, connection.serverName);
    expect(restored?.serverVersion, connection.serverVersion);
    final profile = await store.readProfile();
    expect(profile?.serverAddress, connection.serverAddress);
    expect(profile?.userName, connection.userName);
    await store.deleteConnection();
    expect(await store.readConnection(), isNull);
    expect((await store.readProfile())?.userName, 'listener');
  });
}
