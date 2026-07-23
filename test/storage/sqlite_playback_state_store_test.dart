import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/storage/playback_state_store.dart';
import 'package:gaze/storage/sqlite_playback_state_store.dart';

void main() {
  test('round-trips a versioned playback snapshot', () async {
    final store = SqlitePlaybackStateStore.inMemory();
    final snapshot = StoredPlaybackState(
      serverId: 'server-id',
      userId: 'user-id',
      items: [
        const StoredQueueItem(itemId: 'one', title: 'One', artist: 'Artist'),
        const StoredQueueItem(itemId: 'two', title: 'Two', artist: 'Artist'),
      ],
      currentIndex: 1,
      position: const Duration(seconds: 37),
      volume: 0.72,
      artworkBytes: Uint8List.fromList([1, 2, 3]),
    );

    await store.write(snapshot);
    final restored = await store.read();

    expect(restored, isNotNull);
    expect(restored!.serverId, 'server-id');
    expect(restored.userId, 'user-id');
    expect(restored.currentIndex, 1);
    expect(restored.position, const Duration(seconds: 37));
    expect(restored.volume, 0.72);
    expect(restored.artworkBytes, [1, 2, 3]);
    expect(restored.items.map((item) => item.itemId), ['one', 'two']);
    expect(restored.items.map((item) => item.title), ['One', 'Two']);
    await store.close();
  });

  test('replaces the queue atomically and can clear it', () async {
    final store = SqlitePlaybackStateStore.inMemory();
    await store.write(
      const StoredPlaybackState(
        serverId: 'server-id',
        userId: 'user-id',
        items: [StoredQueueItem(itemId: 'old', title: 'Old', artist: 'Artist')],
        currentIndex: 0,
        position: Duration.zero,
        volume: 1,
      ),
    );
    await store.write(
      const StoredPlaybackState(
        serverId: 'server-id',
        userId: 'user-id',
        items: [StoredQueueItem(itemId: 'new', title: 'New', artist: 'Artist')],
        currentIndex: 0,
        position: Duration(seconds: 2),
        volume: 0.5,
      ),
    );

    expect((await store.read())!.items.single.itemId, 'new');
    await store.clear();
    expect(await store.read(), isNull);
    await store.close();
  });
}
