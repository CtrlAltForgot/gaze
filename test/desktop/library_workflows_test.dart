import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/songs_page.dart';
import 'package:gaze/desktop/playlists_page.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/jellyfin/jellyfin_credential_store.dart';
import 'package:gaze/library/playlist_summary.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/library/track_summary.dart';
import 'package:gaze/storage/library_metadata_cache.dart';
import 'package:gaze/storage/sqlite_library_metadata_cache.dart';
import 'package:gaze/main.dart';
import '../widget_test.dart' as fixtures;

SongSummary song(String id) => SongSummary(
  track: TrackSummary(
    id: id,
    title: id,
    artist: 'Artist',
    duration: const Duration(minutes: 3),
  ),
  album: 'Album',
);
const key = SongLibraryCacheKey(
  serverId: 'test-server-id',
  userId: 'test-user-id',
);
Future<JellyfinConnectionController> connection(
  fixtures.FakeJellyfinApi api,
  SqliteLibraryMetadataCache cache, {
  bool offline = false,
}) async {
  final credentials = fixtures.FakeCredentialStore();
  if (offline)
    credentials.connection = const SavedJellyfinConnection(
      serverAddress: 'http://music.local:8096',
      accessToken: 'test-access-token',
      userId: 'test-user-id',
      userName: 'listener',
      serverId: 'test-server-id',
      serverName: 'Music Server',
      serverVersion: '10.11.0',
    );
  final controller = JellyfinConnectionController(
    apiFactory: (_) => api,
    credentialStore: credentials,
    metadataCache: cache,
  );
  if (offline) {
    await controller.restore();
  } else {
    await controller.connect(
      serverAddress: 'http://music.local:8096',
      userName: 'listener',
      password: 'test-password',
    );
  }
  return controller;
}

Widget songsWidget(
  JellyfinConnectionController controller, {
  Future<void> Function(List<SongSummary>, int)? onPlay,
}) => MaterialApp(
  home: Scaffold(
    body: SongsPage(
      connectionController: controller,
      onConnect: () {},
      onPlaySongs: onPlay ?? (_, _) async {},
      onQueueSong: (_, _) async {},
    ),
  ),
);

class DelayedSongsApi extends fixtures.FakeJellyfinApi {
  final first = Completer<SongPage>();
  final second = Completer<SongPage>();
  final offsets = <int>[];
  @override
  Future<SongPage> getSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) {
    offsets.add(startIndex);
    return startIndex == 0 ? first.future : second.future;
  }
}

class OfflineApi extends fixtures.FakeJellyfinApi {
  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) async => throw const JellyfinConnectionException('Server unavailable.');
}

class PlaylistsApi extends fixtures.FakeJellyfinApi {
  bool fail = false;
  bool empty = false;
  @override
  Future<PlaylistPage> getPlaylists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) async {
    if (fail)
      throw const JellyfinConnectionException('Test server unavailable.');
    return PlaylistPage(
      playlists: empty
          ? []
          : [
              const PlaylistSummary(
                id: 'playlist',
                title: 'Evening mix',
                trackCount: 3,
              ),
            ],
      totalCount: empty ? 0 : 1,
    );
  }

  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) async => SongPage(
    songs: [song('First'), song('Second'), song('First')],
    totalCount: 3,
  );
}

void main() {
  testWidgets('shows the first live page while later songs are still loading', (
    tester,
  ) async {
    final cache = SqliteLibraryMetadataCache.inMemory();
    final api = DelayedSongsApi();
    final ctl = await connection(api, cache);
    addTearDown(ctl.dispose);
    addTearDown(cache.close);
    await tester.pumpWidget(songsWidget(ctl));
    await tester.pump();
    api.first.complete(
      SongPage(songs: [song('First')], totalCount: 2, nextStartIndex: 1),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('First'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(api.offsets, [0, 1]);
    expect(await cache.readSongs(key), isNull);
    api.second.complete(
      SongPage(songs: [song('Second')], totalCount: 2, nextStartIndex: 2),
    );
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    expect((await cache.readSongs(key))!.page.songs.length, 2);
  });
  testWidgets(
    'cached rows remain visible during refresh and a partial failure preserves the cache',
    (tester) async {
      final cache = SqliteLibraryMetadataCache.inMemory();
      await cache.writeSongs(
        key,
        SongPage(songs: [song('Saved')], totalCount: 1),
      );
      final api = DelayedSongsApi();
      final ctl = await connection(api, cache);
      addTearDown(ctl.dispose);
      addTearDown(cache.close);
      await tester.pumpWidget(songsWidget(ctl));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Saved'), findsOneWidget);
      api.first.complete(
        SongPage(songs: [song('Fresh')], totalCount: 2, nextStartIndex: 1),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      api.second.completeError(
        const JellyfinConnectionException('Refresh failed.'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsOneWidget);
      expect(find.textContaining('Could not refresh songs.'), findsOneWidget);
      expect(
        (await cache.readSongs(key))!.page.songs.single.track.title,
        'Saved',
      );
    },
  );
  testWidgets('offline cached songs are browsable with playback disabled', (
    tester,
  ) async {
    final cache = SqliteLibraryMetadataCache.inMemory();
    await cache.writeSongs(
      key,
      SongPage(songs: [song('Saved')], totalCount: 1),
    );
    final ctl = await connection(OfflineApi(), cache, offline: true);
    addTearDown(ctl.dispose);
    addTearDown(cache.close);
    var played = false;
    await tester.pumpWidget(
      songsWidget(
        ctl,
        onPlay: (_, _) async {
          played = true;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline —'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.text('Saved'));
    await tester.pumpAndSettle();
    final button = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Play Saved',
      ),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.text('Saved'));
    await tester.pump();
    expect(played, isFalse);
  });
  testWidgets('offline without a cache explains how to get songs saved', (
    tester,
  ) async {
    final cache = SqliteLibraryMetadataCache.inMemory();
    final ctl = await connection(OfflineApi(), cache, offline: true);
    addTearDown(ctl.dispose);
    addTearDown(cache.close);
    await tester.pumpWidget(songsWidget(ctl));
    await tester.pumpAndSettle();
    expect(find.text('No saved songs yet'), findsOneWidget);
  });
  test(
    'disconnect cancels a refresh without writing another account snapshot',
    () async {
      final cache = SqliteLibraryMetadataCache.inMemory();
      final api = DelayedSongsApi();
      final ctl = await connection(api, cache);
      addTearDown(ctl.dispose);
      addTearDown(cache.close);
      final result = ctl.refreshSongs().toList();
      await Future<void>.delayed(Duration.zero);
      await ctl.disconnect();
      api.first.complete(SongPage(songs: [song('Old account')], totalCount: 1));
      expect(await result, isEmpty);
      expect(await cache.readSongs(key), isNull);
    },
  );
  testWidgets(
    'plays a playlist in saved order, keeps duplicate tracks and exposes its queue',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 720);
      addTearDown(tester.view.reset);
      final cache = SqliteLibraryMetadataCache.inMemory();
      final ctl = await connection(PlaylistsApi(), cache);
      addTearDown(cache.close);
      final playback = fixtures.FakePlaybackController();
      await tester.pumpWidget(
        GazeApp(playbackController: playback, connectionController: ctl),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      final playlistCard = find.descendant(
        of: find.byType(PlaylistsPage),
        matching: find.text('Evening mix'),
      );
      expect(playlistCard, findsOneWidget);
      await tester.tap(playlistCard);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.drag(
        find.descendant(
          of: find.byType(PlaylistsPage),
          matching: find.byType(CustomScrollView),
        ),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      expect(find.text('First'), findsNWidgets(2));
      await tester.ensureVisible(find.byTooltip('Play playlist'));
      await tester.tap(find.byTooltip('Play playlist'));
      await tester.pumpAndSettle();
      expect(playback.loadedRemoteSource!.title, 'First');
      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();
      expect(find.text('Up next · 2'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Up next · 0'), findsOneWidget);
      expect(playback.loadedRemoteSource!.title, 'First');
      for (final width in [850.0, 1280.0, 2048.0]) {
        tester.view.physicalSize = Size(width, 720);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'playlist list covers empty and retryable server failure states',
    (tester) async {
      final cache = SqliteLibraryMetadataCache.inMemory();
      final api = PlaylistsApi()..fail = true;
      final ctl = await connection(api, cache);
      addTearDown(ctl.dispose);
      addTearDown(cache.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistsPage(
              connectionController: ctl,
              onConnect: () {},
              onPlaySongs: (_, _) async {},
              onQueueSongs: (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Playlists could not be loaded'), findsOneWidget);
      api.fail = false;
      api.empty = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('No music playlists yet'), findsOneWidget);
    },
  );
}
