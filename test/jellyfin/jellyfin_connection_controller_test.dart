import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/jellyfin/jellyfin_credential_store.dart';
import 'package:gaze/library/album_summary.dart';
import 'package:gaze/library/track_summary.dart';

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

  test('restores and validates a saved session', () async {
    final credentials = MemoryCredentialStore()
      ..connection = const SavedJellyfinConnection(
        serverAddress: 'http://music.local:8096',
        accessToken: 'saved-token',
        userId: 'test-user-id',
        userName: 'listener',
      );
    final api = RecordingJellyfinApi();
    final controller = JellyfinConnectionController(
      credentialStore: credentials,
      apiFactory: (_) => api,
    );

    await controller.restore();

    expect(controller.state.isConnected, isTrue);
    expect(controller.state.session?.accessToken, 'saved-token');
    expect(api.validatedSession, isTrue);
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
  SavedJellyfinConnection? connection;
  SavedJellyfinProfile? profile;

  String? get accessToken => connection?.accessToken;

  @override
  Future<void> deleteConnection() async => connection = null;

  @override
  Future<String> getOrCreateDeviceId() async => 'stable-device-id';

  @override
  Future<SavedJellyfinConnection?> readConnection() async => connection;

  @override
  Future<SavedJellyfinProfile?> readProfile() async => profile;

  @override
  Future<void> writeConnection(SavedJellyfinConnection value) async =>
      connection = value;

  @override
  Future<void> writeProfile(SavedJellyfinProfile value) async =>
      profile = value;
}

class RecordingJellyfinApi implements JellyfinApi {
  String? receivedPassword;
  bool validatedSession = false;

  @override
  Future<void> reportPlayback({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required JellyfinPlaybackEvent event,
    required String itemId,
    required Duration position,
    required double volume,
    required bool paused,
  }) async {}

  @override
  JellyfinAudioStreamSource createDirectPlaySource({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
  }) => JellyfinAudioStreamSource(
    uri: address.endpoint('/Audio/$itemId/stream'),
    headers: const {'Authorization': 'test-auth-header'},
  );

  @override
  Future<AlbumPage> getAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required AlbumSort sort,
    required int startIndex,
    required int limit,
  }) async => const AlbumPage(albums: [], totalCount: 0);

  @override
  Future<List<TrackSummary>> getAlbumTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String albumId,
  }) async => const [];

  @override
  Future<List<AlbumSummary>> getRecentlyAddedAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    int limit = 10,
  }) async => const [];

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

  @override
  Future<void> validateSession({
    required JellyfinServerAddress address,
    required JellyfinSession session,
  }) async => validatedSession = true;
}

class FailingJellyfinApi implements JellyfinApi {
  @override
  Future<void> reportPlayback({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required JellyfinPlaybackEvent event,
    required String itemId,
    required Duration position,
    required double volume,
    required bool paused,
  }) async {}

  @override
  JellyfinAudioStreamSource createDirectPlaySource({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
  }) => JellyfinAudioStreamSource(
    uri: address.endpoint('/Audio/$itemId/stream'),
    headers: const {},
  );

  @override
  Future<AlbumPage> getAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required AlbumSort sort,
    required int startIndex,
    required int limit,
  }) async => const AlbumPage(albums: [], totalCount: 0);

  @override
  Future<List<TrackSummary>> getAlbumTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String albumId,
  }) async => const [];

  @override
  Future<List<AlbumSummary>> getRecentlyAddedAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    int limit = 10,
  }) async => const [];

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

  @override
  Future<void> validateSession({
    required JellyfinServerAddress address,
    required JellyfinSession session,
  }) async {}
}
