import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/desktop_shell.dart';
import 'package:gaze/jellyfin/http_jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/jellyfin/jellyfin_credential_store.dart';
import 'package:gaze/library/album_summary.dart';
import 'package:gaze/library/song_summary.dart';
import 'package:gaze/main.dart';
import 'package:gaze/storage/library_metadata_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../jellyfin/jellyfin_connection_controller_test.dart'
    show MemoryCredentialStore, RecordingJellyfinApi;
import '../widget_test.dart' show FakeJellyfinApi, FakePlaybackController;

const savedConnection = SavedJellyfinConnection(
  serverAddress: 'https://music.example',
  accessToken: 'saved-token',
  userId: 'test-user-id',
  userName: 'listener',
  serverId: 'test-server-id',
);
const savedPage = AlbumPage(
  albums: [
    AlbumSummary(
      id: 'saved',
      title: 'Saved Album',
      artist: 'Saved Artist',
      imageTag: 'cover',
    ),
  ],
  totalCount: 1,
);

class SavedCache extends DisabledLibraryMetadataCache {
  SavedCache({this.stale = false});
  final bool stale;
  AlbumPage? written;
  @override
  Future<CachedAlbumPage?> readAlbumPage(AlbumPageCacheKey key) async =>
      CachedAlbumPage(
        page: savedPage,
        storedAt: DateTime.now().subtract(
          stale ? const Duration(days: 1) : Duration.zero,
        ),
      );
  @override
  Future<void> writeAlbumPage(AlbumPageCacheKey key, AlbumPage page) async =>
      written = page;
}

class SlowSessionApi extends RecordingJellyfinApi {
  final server = Completer<JellyfinServerInfo>();
  final validation = Completer<void>();
  int serverCalls = 0;
  int validationCalls = 0;
  @override
  Future<JellyfinServerInfo> getPublicServerInfo(
    JellyfinServerAddress address,
  ) {
    serverCalls++;
    return server.future;
  }

  @override
  Future<void> validateSession({
    required JellyfinServerAddress address,
    required JellyfinSession session,
  }) {
    validationCalls++;
    return validation.future;
  }

  void finish() {
    server.complete(
      const JellyfinServerInfo(
        id: 'test-server-id',
        name: 'Music',
        version: '10',
      ),
    );
    validation.complete();
  }
}

class SlowAlbumsApi extends RecordingJellyfinApi {
  final albums = Completer<AlbumPage>();
  @override
  Future<AlbumPage> getAlbums({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required AlbumSort sort,
    required int startIndex,
    required int limit,
  }) => albums.future;
}

class CountingApi extends FakeJellyfinApi {
  int songCalls = 0;
  int artworkCalls = 0;
  @override
  Future<SongPage> getSongs({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) {
    songCalls++;
    return super.getSongs(
      address: address,
      session: session,
      startIndex: startIndex,
      limit: limit,
    );
  }

  @override
  Future<Uint8List?> getArtwork({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
    required String? imageTag,
  }) async {
    artworkCalls++;
    return Uint8List.fromList([1, 2, 3]);
  }
}

void main() {
  test(
    'saved albums are available before either startup network check completes',
    () async {
      final api = SlowSessionApi();
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: MemoryCredentialStore()..connection = savedConnection,
        metadataCache: SavedCache(),
      );
      addTearDown(controller.dispose);
      final restoring = controller.states.firstWhere(
        (s) => s.status == JellyfinConnectionStatus.restoring,
      );
      final completion = controller.restore();
      await restoring;
      expect(api.serverCalls, 1);
      expect(api.validationCalls, 1);
      expect(controller.state.isConnected, isFalse);
      expect(
        (await controller.loadAlbums(
          sort: AlbumSort.title,
          startIndex: 0,
        )).albums.single.title,
        'Saved Album',
      );
      expect(
        () => controller.createDirectPlaySource('song'),
        throwsA(isA<JellyfinConnectionException>()),
      );
      api.finish();
      await completion;
      expect(controller.state.isConnected, isTrue);
    },
  );

  test('disconnect invalidates an unfinished startup restore', () async {
    final api = SlowSessionApi();
    final credentials = MemoryCredentialStore()..connection = savedConnection;
    final controller = JellyfinConnectionController(
      apiFactory: (_) => api,
      credentialStore: credentials,
    );
    addTearDown(controller.dispose);
    final restoring = controller.states.firstWhere(
      (s) => s.status == JellyfinConnectionStatus.restoring,
    );
    final completion = controller.restore();
    await restoring;
    await controller.disconnect();
    api.finish();
    await completion;
    expect(controller.state.canBrowseLibrary, isFalse);
    expect(credentials.connection, isNull);
  });

  test(
    'expired saved pages arrive before a stalled refresh and survive its failure',
    () async {
      final api = SlowAlbumsApi();
      final cache = SavedCache(stale: true);
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: MemoryCredentialStore(),
        metadataCache: cache,
      );
      addTearDown(controller.dispose);
      await controller.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      final pages = StreamIterator(
        controller.watchAlbums(sort: AlbumSort.title, startIndex: 0),
      );
      expect(await pages.moveNext(), isTrue);
      expect(pages.current.albums.single.title, 'Saved Album');
      expect(pages.current.isStale, isTrue);
      final refresh = pages.moveNext();
      await Future<void>.delayed(Duration.zero);
      api.albums.completeError(const JellyfinConnectionException('Offline'));
      expect(await refresh, isTrue);
      expect(pages.current.albums.single.title, 'Saved Album');
      expect(await pages.moveNext(), isFalse);
      expect(cache.written, isNull);
    },
  );

  test(
    'late album responses cannot repopulate the cache after sign-out',
    () async {
      final api = SlowAlbumsApi();
      final cache = SavedCache(stale: true);
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: MemoryCredentialStore(),
        metadataCache: cache,
      );
      addTearDown(controller.dispose);
      await controller.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      final pages = StreamIterator(
        controller.watchAlbums(sort: AlbumSort.title, startIndex: 0),
      );
      await pages.moveNext();
      final refresh = pages.moveNext();
      await Future<void>.delayed(Duration.zero);
      await controller.disconnect();
      api.albums.complete(savedPage);
      expect(await refresh, isFalse);
      expect(cache.written, isNull);
    },
  );

  test(
    'album, artist and search lists make no image requests before returning',
    () async {
      var imageRequests = 0;
      final api = HttpJellyfinApi(
        identity: const JellyfinClientIdentity(deviceId: 'test'),
        client: MockClient((request) async {
          if (request.url.path.contains('/Images/')) {
            imageRequests++;
            throw StateError('Metadata must not wait for artwork');
          }
          return http.Response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'album',
                  'Name': 'Album',
                  'Type': 'MusicAlbum',
                  'ImageTags': {'Primary': 'cover'},
                },
                {
                  'Id': 'track',
                  'Name': 'Track',
                  'Type': 'Audio',
                  'AlbumId': 'album',
                  'AlbumPrimaryImageTag': 'cover',
                },
              ],
              'TotalRecordCount': 2,
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final address = JellyfinServerAddress.parse('https://music.example');
      const session = JellyfinSession(
        accessToken: 'test',
        userId: 'user',
        userName: 'listener',
      );
      expect(
        (await api.getAlbums(
          address: address,
          session: session,
          sort: AlbumSort.title,
          startIndex: 0,
          limit: 24,
        )).albums,
        isNotEmpty,
      );
      expect(
        (await api.getArtists(
          address: address,
          session: session,
          startIndex: 0,
          limit: 48,
        )).artists,
        isNotEmpty,
      );
      expect(
        await api.getArtistAlbums(
          address: address,
          session: session,
          artistId: 'artist',
        ),
        isNotEmpty,
      );
      final search = await api.searchLibrary(
        address: address,
        session: session,
        query: 'music',
      );
      expect(search.tracks.single.albumId, 'album');
      expect(imageRequests, 0);
    },
  );

  test('artwork memory cache is reused and cleared at sign-out', () async {
    final api = CountingApi();
    final controller = JellyfinConnectionController(
      apiFactory: (_) => api,
      credentialStore: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.connect(
      serverAddress: 'https://music.example',
      userName: 'listener',
      password: 'test',
    );
    await controller.loadArtwork('album', 'tag');
    await controller.loadArtwork('album', 'tag');
    expect(api.artworkCalls, 1);
    expect(controller.peekArtwork('album', 'tag'), isNotNull);
    await controller.disconnect();
    expect(controller.peekArtwork('album', 'tag'), isNull);
  });

  testWidgets(
    'saved Home is visible while startup networking is still pending',
    (tester) async {
      final api = SlowSessionApi();
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: MemoryCredentialStore()..connection = savedConnection,
        metadataCache: SavedCache(),
      );
      await tester.pumpWidget(
        GazeApp(
          playbackController: FakePlaybackController(),
          connectionController: controller,
        ),
      );
      final completion = controller.restore();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('Saved Album'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(api.validation.isCompleted, isFalse);
      api.finish();
      await completion;
      await tester.pumpAndSettle();
      expect(find.text('Saved Album'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'returning to Songs reuses loaded rows without another library request',
    (tester) async {
      final api = CountingApi();
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: MemoryCredentialStore(),
      );
      await controller.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      await tester.pumpWidget(
        GazeApp(
          playbackController: FakePlaybackController(),
          connectionController: controller,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Songs'));
      await tester.pumpAndSettle();
      expect(api.songCalls, 1);
      await tester.tap(find.bySemanticsLabel('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Songs'));
      await tester.pumpAndSettle();
      expect(api.songCalls, 1);
      expect(find.byType(DesktopShell), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
