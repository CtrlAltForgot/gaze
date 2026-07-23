import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/jellyfin/jellyfin_credential_store.dart';
import 'package:gaze/library/album_summary.dart';
import 'package:gaze/library/track_summary.dart';
import 'package:gaze/main.dart';
import 'package:gaze/playback/playback_controller.dart';

void main() {
  testWidgets('shows the desktop shell by default', (tester) async {
    final controller = FakePlaybackController();

    await tester.pumpWidget(
      GazeApp(
        playbackController: controller,
        connectionController: createFakeConnectionController(),
      ),
    );

    expect(find.text('g'), findsOneWidget);
    expect(find.text('Your music, brought forward.'), findsOneWidget);
    expect(find.text('Recently added'), findsNothing);
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.text('Connect your Jellyfin library'), findsOneWidget);
  });

  testWidgets('keeps the playback technical test reachable', (tester) async {
    final controller = FakePlaybackController();

    await tester.pumpWidget(
      GazeApp(
        playbackController: controller,
        connectionController: createFakeConnectionController(),
      ),
    );
    await tester.tap(find.byTooltip('Open the playback technical test'));
    await tester.pumpAndSettle();

    expect(find.text('gaze playback technical test'), findsOneWidget);
    expect(find.text('Choose local audio file'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Load remote URL'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Playback state: idle'), findsOneWidget);
    expect(find.text('Completion: not reached'), findsOneWidget);
    expect(find.text('Error output:'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://example.com/audio.flac',
    );
    await tester.tap(find.text('Load remote URL'));
    await tester.pump();

    expect(controller.loadedRemoteUrl.toString(), endsWith('audio.flac'));
    expect(find.textContaining('Source: https://example.com'), findsOneWidget);
  });

  testWidgets('connects through the temporary Jellyfin screen', (tester) async {
    final credentials = FakeCredentialStore();
    final connectionController = createFakeConnectionController(credentials);

    await tester.pumpWidget(
      GazeApp(
        playbackController: FakePlaybackController(),
        connectionController: connectionController,
      ),
    );
    await tester.tap(find.byTooltip('Connect to Jellyfin'));
    await tester.pumpAndSettle();

    expect(find.text('Connect Jellyfin'), findsOneWidget);
    expect(find.text('Bring your library into gaze'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Jellyfin server address'),
      'http://music.local:8096',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Username'),
      'listener',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'not-a-real-password',
    );
    await tester.pump();

    expect(find.textContaining('HTTP is unencrypted'), findsOneWidget);
    final connectButton = find.widgetWithText(FilledButton, 'Connect');
    await tester.ensureVisible(connectButton);
    await tester.tap(connectButton);
    await tester.pumpAndSettle();

    expect(find.text('Connected to Music Server'), findsOneWidget);
    expect(credentials.accessToken, 'test-access-token');
  });

  testWidgets('shows real recently added albums after connection', (
    tester,
  ) async {
    final connectionController = createFakeConnectionController();
    await connectionController.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'temporary-password',
    );

    await tester.pumpWidget(
      GazeApp(
        playbackController: FakePlaybackController(),
        connectionController: connectionController,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Real Album'), findsOneWidget);
    expect(find.text('Real Artist'), findsOneWidget);
    expect(find.text('Northern Lines'), findsNothing);
  });

  testWidgets('opens a recently added album and plays one of its tracks', (
    tester,
  ) async {
    final connectionController = createFakeConnectionController();
    final playbackController = FakePlaybackController();
    await connectionController.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'temporary-password',
    );

    await tester.pumpWidget(
      GazeApp(
        playbackController: playbackController,
        connectionController: connectionController,
      ),
    );
    await tester.pumpAndSettle();

    final homeAlbum = find.text('Real Album');
    await tester.ensureVisible(homeAlbum);
    await tester.pumpAndSettle();
    await tester.tap(homeAlbum);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextButton, 'Home'), findsOneWidget);
    expect(find.text('Real Track'), findsOneWidget);

    await tester.tap(find.text('Real Track'));
    await tester.pumpAndSettle();

    expect(playbackController.loadedRemoteSource?.title, 'Real Track');
    expect(
      playbackController.loadedRemoteSource?.headers['Authorization'],
      'test-auth-header',
    );

    await tester.tap(find.widgetWithText(TextButton, 'Home'));
    await tester.pumpAndSettle();

    expect(find.text('Your music, brought forward.'), findsOneWidget);
    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text('Real Album'), findsOneWidget);
  });

  testWidgets('browses albums and opens a track listing', (tester) async {
    final connectionController = createFakeConnectionController();
    final playbackController = FakePlaybackController();
    await connectionController.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'temporary-password',
    );
    await tester.pumpWidget(
      GazeApp(
        playbackController: playbackController,
        connectionController: connectionController,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Albums'));
    await tester.pumpAndSettle();

    expect(find.text('1 album'), findsOneWidget);
    expect(find.text('Real Album'), findsOneWidget);
    expect(find.text('Real Artist · 2026'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);

    await tester.tap(find.text('Real Album'));
    await tester.pumpAndSettle();

    expect(find.text('All albums'), findsOneWidget);
    expect(find.text('Real Track'), findsOneWidget);
    expect(find.text('3:12'), findsOneWidget);
    expect(find.byKey(const ValueKey('play')), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.text('Real Track')));
    await tester.pump(const Duration(milliseconds: 70));
    expect(find.byKey(const ValueKey('play')), findsOneWidget);

    await tester.tap(find.text('Real Track'));
    await tester.pumpAndSettle();

    expect(playbackController.loadedRemoteSource?.title, 'Real Track');
    expect(
      playbackController.loadedRemoteSource?.headers['Authorization'],
      'test-auth-header',
    );
    expect(find.text('Real Track'), findsWidgets);
  });
}

JellyfinConnectionController createFakeConnectionController([
  FakeCredentialStore? credentials,
]) {
  return JellyfinConnectionController(
    credentialStore: credentials ?? FakeCredentialStore(),
    apiFactory: (_) => FakeJellyfinApi(),
  );
}

class FakePlaybackController implements PlaybackController {
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot _state = const PlaybackSnapshot();
  Uri? loadedRemoteUrl;
  RemotePlaybackSource? loadedRemoteSource;

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  Future<void> loadLocalFile(String path) async {}

  @override
  Future<void> loadRemoteUrl(Uri url) async {
    loadedRemoteUrl = url;
    _state = _state.copyWith(
      status: PlaybackStatus.ready,
      sourceLabel: url.toString(),
    );
    _states.add(_state);
  }

  @override
  Future<void> loadRemoteSource(RemotePlaybackSource source) async {
    loadedRemoteSource = source;
    loadedRemoteUrl = source.uri;
    _state = PlaybackSnapshot(
      status: PlaybackStatus.ready,
      sourceLabel: source.title,
      title: source.title,
      artist: source.artist,
      artworkBytes: source.artworkBytes,
      itemId: source.itemId,
    );
    _states.add(_state);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _states.close();
}

class FakeCredentialStore implements JellyfinCredentialStore {
  SavedJellyfinConnection? connection;
  SavedJellyfinProfile? profile;

  String? get accessToken => connection?.accessToken;

  @override
  Future<void> deleteConnection() async => connection = null;

  @override
  Future<String> getOrCreateDeviceId() async => 'test-device-id';

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

class FakeJellyfinApi implements JellyfinApi {
  static const album = AlbumSummary(
    id: 'album-id',
    title: 'Real Album',
    artist: 'Real Artist',
    year: 2026,
  );

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
  }) async => const AlbumPage(albums: [album], totalCount: 1);

  @override
  Future<List<TrackSummary>> getAlbumTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String albumId,
  }) async => const [
    TrackSummary(
      id: 'track-id',
      title: 'Real Track',
      artist: 'Real Artist',
      duration: Duration(minutes: 3, seconds: 12),
      trackNumber: 1,
    ),
  ];

  @override
  Future<List<AlbumSummary>> getRecentlyAddedAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    int limit = 10,
  }) async => const [album];

  @override
  Future<JellyfinSession> authenticate({
    required JellyfinServerAddress address,
    required String userName,
    required String password,
  }) async {
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
  }) async {}
}
