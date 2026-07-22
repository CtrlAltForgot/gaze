import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/flutter_secure_jellyfin_credential_store.dart';

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

  test('writes, reads, and deletes the access token', () async {
    const store = FlutterSecureJellyfinCredentialStore();

    expect(await store.readAccessToken(), isNull);
    await store.writeAccessToken('test-token');
    expect(await store.readAccessToken(), 'test-token');
    await store.deleteAccessToken();
    expect(await store.readAccessToken(), isNull);
  });
}
