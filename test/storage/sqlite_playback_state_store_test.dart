import 'dart:typed_data';
import 'package:sqlite3/sqlite3.dart';
import 'package:gaze/playback/playback_queue_controller.dart';

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
        const StoredQueueItem(
          itemId: 'one',
          title: 'One',
          artist: 'Artist',
          artworkId: 'album-one',
          artworkTag: 'cover-one',
        ),
        const StoredQueueItem(itemId: 'two', title: 'Two', artist: 'Artist'),
      ],
      currentIndex: 1,
      position: const Duration(seconds: 37),
      volume: 0.72,
      shuffleEnabled: true,
      repeatMode: PlaybackRepeatMode.one,
      originalOrder: [1, 0],
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
    expect(restored.shuffleEnabled, isTrue);
    expect(restored.repeatMode, PlaybackRepeatMode.one);
    expect(restored.originalOrder, [1, 0]);
    expect(restored.artworkBytes, [1, 2, 3]);
    expect(restored.items.map((item) => item.itemId), ['one', 'two']);
    expect(restored.items.map((item) => item.title), ['One', 'Two']);
    expect(restored.items.first.artworkId, 'album-one');
    expect(restored.items.first.artworkTag, 'cover-one');
    expect(restored.items.last.artworkId, isNull);
    await store.close();
  });

  test(
    'migrates a version 2 listening snapshot without losing the queue',
    () async {
      final db = sqlite3.openInMemory();
      db.execute('''
      CREATE TABLE playback_state (singleton_id INTEGER PRIMARY KEY, server_id TEXT,
        user_id TEXT, current_index INTEGER, position_ms INTEGER, volume REAL,
        artwork BLOB, updated_at_ms INTEGER);
      CREATE TABLE queue_items (queue_position INTEGER PRIMARY KEY,
        item_id TEXT, title TEXT, artist TEXT);
      INSERT INTO playback_state VALUES (1, 'server', 'user', 0, 12000, 0.6, NULL, 0);
      INSERT INTO queue_items VALUES (0, 'song', 'Song', 'Artist');
      PRAGMA user_version = 2;
    ''');
      final store = SqlitePlaybackStateStore.fromDatabase(db);
      final saved = (await store.read())!;
      expect(db.userVersion, 4);
      expect(saved.items.single.artworkId, isNull);
      expect(saved.items.single.artworkTag, isNull);
      expect(saved.items.single.itemId, 'song');
      expect(saved.position, const Duration(seconds: 12));
      expect(saved.volume, .6);
      expect(saved.shuffleEnabled, isFalse);
      expect(saved.repeatMode, PlaybackRepeatMode.off);
      expect(saved.originalOrder, isEmpty);
      await store.write(saved);
      expect((await store.read())!.items.single.title, 'Song');
      await store.close();
    },
  );

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
