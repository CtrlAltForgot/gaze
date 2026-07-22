import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/jellyfin/jellyfin_credential_store.dart';

void main() {
  test('connects and saves only the returned access token', () async {
    final credentials = MemoryCredentialStore();
    final api = RecordingJellyfinApi();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (deviceId) {
        expect(deviceId, 'stable-device-id');
        return api;
      },
    );

    await controller.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'temporary-password',
    );

    expect(controller.state.isConnected, isTrue);
    expect(controller.state.serverInfo?.name, 'Music Server');
    expect(credentials.accessToken, 'test-access-token');
    expect(api.receivedPassword, 'temporary-password');
    await controller.dispose();
  });

  test('disconnect removes the token', () async {
    final credentials = MemoryCredentialStore();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (_) => RecordingJellyfinApi(),
    );
    await controller.connect(
      serverAddress: 'https://music.example',
      userName: 'listener',
      password: 'temporary-password',
    );

    await controller.disconnect();

    expect(controller.state.isConnected, isFalse);
    expect(credentials.accessToken, isNull);
    await controller.dispose();
  });

  test('shows safe connection errors without saving a token', () async {
    final credentials = MemoryCredentialStore();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (_) => FailingJellyfinApi(),
    );

    await controller.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'temporary-password',
    );

    expect(controller.state.isConnected, isFalse);
    expect(controller.state.errorMessage, 'Could not reach the test server.');
    expect(credentials.accessToken, isNull);
    await controller.dispose();
  });
}

class MemoryCredentialStore implements JellyfinCredentialStore {
  String? accessToken;

  @override
  Future<void> deleteAccessToken() async => accessToken = null;

  @override
  Future<String> getOrCreateDeviceId() async => 'stable-device-id';

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<void> writeAccessToken(String token) async => accessToken = token;
}

class RecordingJellyfinApi implements JellyfinApi {
  String? receivedPassword;

  @override
  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  }) async {
    receivedPassword = password;
    return JellyfinSession(
      accessToken: 'test-access-token',
      userId: 'test-user-id',
      userName: userName,
    );
  }

  @override
  void close() {}

  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) async {
    return const JellyfinServerInfo(
      id: 'test-server-id',
      name: 'Music Server',
      version: '10.11.0',
    );
  }
}

class FailingJellyfinApi implements JellyfinApi {
  @override
  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  }) {
    throw UnimplementedError();
  }

  @override
  void close() {}

  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) {
    throw const JellyfinConnectionException('Could not reach the test server.');
  }
}
