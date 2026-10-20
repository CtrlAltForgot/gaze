import 'dart:typed_data';
import 'package:gaze/storage/playback_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/application/playback_state_coordinator.dart';
import 'package:gaze/playback/playback_controller.dart';
import 'package:gaze/playback/playback_queue_controller.dart';
import 'package:gaze/storage/sqlite_playback_state_store.dart';
import '../widget_test.dart' as fixtures;

RemotePlaybackSource source(String id) => RemotePlaybackSource(
  uri: Uri.parse('https://music.example/$id'),
  title: id,
  artist: 'Artist',
  itemId: id,
  artworkId: 'album-$id',
  artworkTag: 'cover-$id',
);
void main() {
  test(
    'restoring a queue retains each cover and gives legacy tracks a lookup identity',
    () async {
      final connection = fixtures.createFakeConnectionController();
      await connection.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test-password',
      );
      final playback = fixtures.FakePlaybackController();
      final queue = PlaybackQueueController(playbackController: playback);
      final store = SqlitePlaybackStateStore.inMemory();
      await store.write(
        StoredPlaybackState(
          serverId: connection.state.serverInfo!.id,
          userId: connection.state.session!.userId,
          items: const [
            StoredQueueItem(
              itemId: 'one',
              title: 'One',
              artist: 'Artist',
              artworkId: 'album-one',
              artworkTag: 'tag-one',
            ),
            StoredQueueItem(itemId: 'two', title: 'Two', artist: 'Artist'),
          ],
          currentIndex: 0,
          position: const Duration(seconds: 20),
          volume: .5,
          artworkBytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      final coordinator = PlaybackStateCoordinator(
        playbackController: playback,
        queueController: queue,
        connectionController: connection,
        store: store,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(queue.state.items.first.artworkId, 'album-one');
      expect(queue.state.items.first.artworkTag, 'tag-one');
      expect(queue.state.items.first.artworkBytes, [1, 2, 3]);
      expect(queue.state.items.last.artworkId, 'two');
      expect(queue.state.items.last.artworkTag, isNull);
      expect(queue.state.items.last.artworkBytes, isNull);
      await coordinator.dispose();
      await queue.dispose();
      await playback.dispose();
      await connection.dispose();
    },
  );

  test(
    'queue edits persist in SQLite without changing current item or playback position',
    () async {
      final connection = fixtures.createFakeConnectionController();
      await connection.connect(
        serverAddress: 'https://music.example',
        userName: 'listener',
        password: 'test-password',
      );
      final playback = fixtures.FakePlaybackController();
      final queue = PlaybackQueueController(playbackController: playback);
      final store = SqlitePlaybackStateStore.inMemory();
      final coordinator = PlaybackStateCoordinator(
        playbackController: playback,
        queueController: queue,
        connectionController: connection,
        store: store,
      );
      await Future<void>.delayed(Duration.zero);
      await queue.playAlbum([
        source('One'),
        source('Two'),
        source('Three'),
      ], startIndex: 0);
      await queue.enqueue([source('Next')], next: true);
      queue.moveUpcoming(3, 1);
      queue.removeAt(2);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final saved = await store.read();
      expect(saved, isNotNull);
      expect(saved!.items.map((s) => s.itemId), ['One', 'Three', 'Two']);
      expect(saved.currentIndex, 0);
      expect(saved.items.first.artworkId, 'album-One');
      expect(saved.items.first.artworkTag, 'cover-One');
      expect(playback.loadedRemoteSource!.itemId, 'One');
      queue.setShuffle(true);
      queue.setRepeatMode(PlaybackRepeatMode.one);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final modes = (await store.read())!;
      expect(modes.shuffleEnabled, isTrue);
      expect(modes.repeatMode, PlaybackRepeatMode.one);
      expect(modes.originalOrder, queue.state.originalOrder);
      queue.clearUpcoming();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect((await store.read())!.items.map((s) => s.itemId), ['One']);
      await coordinator.dispose();
      await queue.dispose();
      await playback.dispose();
      await connection.dispose();
    },
  );
}
