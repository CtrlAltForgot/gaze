import 'dart:io';
import 'dart:convert';

import '../playback/playback_queue_controller.dart';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'playback_state_store.dart';

class SqlitePlaybackStateStore implements PlaybackStateStore {
  SqlitePlaybackStateStore.fromDatabase(this._database) {
    _migrate();
  }

  final Database _database;

  static Future<SqlitePlaybackStateStore> open() async {
    final supportDirectory = await getApplicationSupportDirectory();
    await supportDirectory.create(recursive: true);
    final databasePath =
        '${supportDirectory.path}${Platform.pathSeparator}gaze.sqlite3';
    return SqlitePlaybackStateStore.fromDatabase(sqlite3.open(databasePath));
  }

  static SqlitePlaybackStateStore inMemory() =>
      SqlitePlaybackStateStore.fromDatabase(sqlite3.openInMemory());

  void _migrate() {
    final version = _database.userVersion;
    if (version > 4) {
      throw StateError('The gaze database was created by a newer version.');
    }
    if (version == 0) {
      _database.execute('''
        CREATE TABLE playback_state (
          singleton_id INTEGER NOT NULL PRIMARY KEY CHECK (singleton_id = 1),
          server_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          current_index INTEGER NOT NULL,
          position_ms INTEGER NOT NULL,
          volume REAL NOT NULL,
          artwork BLOB,
          updated_at_ms INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE queue_items (
          queue_position INTEGER NOT NULL PRIMARY KEY,
          item_id TEXT NOT NULL,
          title TEXT NOT NULL,
          artist TEXT NOT NULL
        ) STRICT;
      ''');
      _database.userVersion = 2;
    } else if (version == 1) {
      _database.execute('ALTER TABLE playback_state ADD COLUMN artwork BLOB');
      _database.userVersion = 2;
    }
    if (_database.userVersion == 2) {
      _database.execute('BEGIN IMMEDIATE');
      try {
        _database.execute(
          "ALTER TABLE playback_state ADD COLUMN shuffle_enabled INTEGER NOT NULL DEFAULT 0",
        );
        _database.execute(
          "ALTER TABLE playback_state ADD COLUMN repeat_mode TEXT NOT NULL DEFAULT 'off'",
        );
        _database.execute(
          "ALTER TABLE playback_state ADD COLUMN original_order TEXT NOT NULL DEFAULT '[]'",
        );
        _database.userVersion = 3;
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    }
    if (_database.userVersion == 3) {
      _database.execute('BEGIN IMMEDIATE');
      try {
        _database.execute('ALTER TABLE queue_items ADD COLUMN artwork_id TEXT');
        _database.execute(
          'ALTER TABLE queue_items ADD COLUMN artwork_tag TEXT',
        );
        _database.userVersion = 4;
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  @override
  Future<StoredPlaybackState?> read() async {
    final stateRows = _database.select('''
      SELECT server_id, user_id, current_index, position_ms, volume, artwork,
             shuffle_enabled, repeat_mode, original_order
      FROM playback_state
      WHERE singleton_id = 1
    ''');
    if (stateRows.isEmpty) {
      return null;
    }
    final itemRows = _database.select('''
      SELECT item_id, title, artist, artwork_id, artwork_tag
      FROM queue_items
      ORDER BY queue_position
    ''');
    final row = stateRows.single;
    final items = itemRows
        .map(
          (item) => StoredQueueItem(
            itemId: item['item_id'] as String,
            title: item['title'] as String,
            artist: item['artist'] as String,
            artworkId: item['artwork_id'] as String?,
            artworkTag: item['artwork_tag'] as String?,
          ),
        )
        .toList(growable: false);
    final currentIndex = row['current_index'] as int;
    if (items.isEmpty || currentIndex < 0 || currentIndex >= items.length) {
      return null;
    }
    return StoredPlaybackState(
      serverId: row['server_id'] as String,
      userId: row['user_id'] as String,
      items: items,
      currentIndex: currentIndex,
      position: Duration(
        milliseconds: (row['position_ms'] as int).clamp(0, 1 << 53),
      ),
      volume: (row['volume'] as num).toDouble().clamp(0, 1),
      artworkBytes: row['artwork'] as Uint8List?,
      shuffleEnabled: row['shuffle_enabled'] == 1,
      repeatMode: PlaybackRepeatMode.values.firstWhere(
        (mode) => mode.name == row['repeat_mode'],
        orElse: () => PlaybackRepeatMode.off,
      ),
      originalOrder: _readOrder(row['original_order'] as String),
    );
  }

  List<int> _readOrder(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List && decoded.every((item) => item is int)) {
        return decoded.cast<int>();
      }
    } catch (_) {
      // A damaged ordering hint must not prevent restoring the queue.
    }
    return const [];
  }

  @override
  Future<void> write(StoredPlaybackState state) async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute('DELETE FROM queue_items');
      final insertItem = _database.prepare('''
        INSERT INTO queue_items (queue_position, item_id, title, artist, artwork_id, artwork_tag)
        VALUES (?, ?, ?, ?, ?, ?)
      ''');
      try {
        for (var index = 0; index < state.items.length; index++) {
          final item = state.items[index];
          insertItem.execute([
            index,
            item.itemId,
            item.title,
            item.artist,
            item.artworkId,
            item.artworkTag,
          ]);
        }
      } finally {
        insertItem.close();
      }
      _database.execute(
        '''
        INSERT OR REPLACE INTO playback_state (
          singleton_id, server_id, user_id, current_index, position_ms,
          volume, artwork, updated_at_ms, shuffle_enabled, repeat_mode, original_order
        ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [
          state.serverId,
          state.userId,
          state.currentIndex,
          state.position.inMilliseconds,
          state.volume,
          state.artworkBytes,
          DateTime.now().millisecondsSinceEpoch,
          state.shuffleEnabled ? 1 : 0,
          state.repeatMode.name,
          jsonEncode(state.originalOrder),
        ],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> clear() async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute('DELETE FROM queue_items');
      _database.execute('DELETE FROM playback_state');
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> close() async => _database.close();
}
