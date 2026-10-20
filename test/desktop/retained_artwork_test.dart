import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/desktop/library_artwork.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/library/artist_summary.dart';
import 'package:gaze/storage/artwork_cache.dart';
import 'package:gaze/storage/file_artwork_cache.dart';
import 'package:gaze/storage/library_metadata_cache.dart';
import 'package:gaze/storage/sqlite_library_metadata_cache.dart';
import '../widget_test.dart' show FakeJellyfinApi, FakeCredentialStore;

class SlowArtApi extends FakeJellyfinApi {
  final artwork = Completer<Uint8List?>();
  final artists = Completer<ArtistPage>();
  @override
  Future<Uint8List?> getArtwork({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String itemId,
    required String? imageTag,
  }) => artwork.future;
  @override
  Future<ArtistPage> getArtists({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required int startIndex,
    required int limit,
  }) => artists.future;
}

void main() {
  testWidgets(
    'a retained local image appears before the network completes and survives tag refresh',
    (tester) async {
      late Directory directory;
      late FileArtworkCache cache;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('gaze-retained-');
        cache = FileArtworkCache(directory: directory);
        await cache.write(
          const ArtworkCacheKey(
            server: 'https://music.example',
            itemId: 'artist',
            imageTag: 'old',
            maxWidth: 600,
          ),
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5XcAAAAASUVORK5CYII=',
          ),
        );
      });
      final api = SlowArtApi();
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: FakeCredentialStore(),
        artworkCache: cache,
      );
      await controller.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      Widget view(String tag) => MaterialApp(
        home: LibraryArtwork(
          connectionController: controller,
          itemId: 'artist',
          imageTag: tag,
        ),
      );
      await tester.pumpWidget(view('old'));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      await tester.pumpWidget(view('new'));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      api.artwork.complete(null);
      await tester.pump();
      expect(find.byType(Icon), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
  test(
    'saved artists emit while a live refresh is blocked and survive its failure',
    () async {
      final api = SlowArtApi();
      final metadata = SqliteLibraryMetadataCache.inMemory();
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: FakeCredentialStore(),
        metadataCache: metadata,
      );
      await controller.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      final state = controller.state;
      await metadata.writeArtistPage(
        ArtistPageCacheKey(
          serverId: state.serverInfo!.id,
          userId: state.session!.userId,
          startIndex: 0,
          limit: 48,
        ),
        const ArtistPage(
          artists: [ArtistSummary(id: 'saved', name: 'Saved Artist')],
          totalCount: 1,
        ),
      );
      final values = <ArtistPage>[];
      final done = Completer<void>();
      final subscription = controller
          .watchArtists(startIndex: 0, limit: 48)
          .listen(values.add, onDone: done.complete);
      await Future<void>.delayed(Duration.zero);
      expect(values.single.artists.single.name, 'Saved Artist');
      api.artists.completeError(const JellyfinConnectionException('Offline'));
      await done.future;
      expect(values, hasLength(1));
      await subscription.cancel();
      await controller.dispose();
      await metadata.close();
    },
  );
}
