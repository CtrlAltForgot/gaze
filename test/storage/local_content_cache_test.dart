import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/storage/local_content_cache.dart';
import 'package:gaze/storage/playlist_snapshot.dart';
import 'package:gaze/jellyfin/jellyfin_connection_controller.dart';
import 'package:gaze/jellyfin/jellyfin_api.dart';
import 'package:gaze/library/song_summary.dart';
import '../widget_test.dart' as fixtures;
import '../desktop/playlist_management_test.dart' show ManagedApi;

class DelayedPlaylistApi extends ManagedApi {
  Completer<SongPage>? pending;
  @override
  Future<SongPage> getPlaylistTracks({
    required JellyfinServerAddress address,
    required JellyfinSession session,
    required String playlistId,
    required int startIndex,
    required int limit,
  }) =>
      pending?.future ??
      super.getPlaylistTracks(
        address: address,
        session: session,
        playlistId: playlistId,
        startIndex: startIndex,
        limit: limit,
      );
}

void main() {
  test(
    'cache bounds entries, honors expiry, and keeps keys separate',
    () async {
      final cache = SqliteLocalContentCache.inMemory();
      addTearDown(cache.dispose);
      await cache.write(
        'account-a:mix',
        'old',
        ttl: const Duration(seconds: -1),
      );
      await cache.write('account-b:mix', 'new');
      expect(await cache.read('account-a:mix'), isNull);
      expect(await cache.read('account-b:mix'), 'new');
      await cache.write('large', 'x' * (4 * 1024 * 1024 + 1));
      expect(await cache.read('large'), isNull);
    },
  );
  test(
    'complete playlist snapshots render before slow refresh, preserving repeats',
    () async {
      final cache = SqliteLocalContentCache.inMemory();
      addTearDown(cache.dispose);
      final api = DelayedPlaylistApi();
      final controller = JellyfinConnectionController(
        apiFactory: (_) => api,
        credentialStore: fixtures.FakeCredentialStore(),
        contentCache: cache,
      );
      addTearDown(controller.dispose);
      await controller.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test',
      );
      final first = (await controller.loadPlaylistTracks('mix').toList()).last;
      expect(first.songs.length, 2);
      final decoded = decodePlaylistSnapshot(encodePlaylistSnapshot(first));
      expect(
        decoded.songs.map((s) => s.entryId),
        first.songs.map((s) => s.entryId),
      );
      expect(
        decoded.songs.map((s) => s.track.id),
        first.songs.map((s) => s.track.id),
      );
      api.pending = Completer<SongPage>();
      final emitted = <SongPage>[];
      final ready = Completer<void>();
      final subscription = controller.loadPlaylistTracks('mix').listen((page) {
        emitted.add(page);
        if (!ready.isCompleted) ready.complete();
      });
      await ready.future;
      expect(emitted.single.fromCache, isTrue);
      expect(emitted.single.songs.length, 2);
      api.pending!.complete(const SongPage(songs: [], totalCount: 0));
      await subscription.asFuture<void>();
      expect(emitted.last.fromCache, isFalse);
      expect(emitted.last.songs, isEmpty);
      expect(
        decodePlaylistSnapshot(
          (await cache.read('playlist:${controller.accountKey}:mix'))!,
        ).songs,
        isEmpty,
      );
    },
  );
}
