import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../library/album_summary.dart';
import 'library_metadata_cache.dart';

class SqliteLibraryMetadataCache implements LibraryMetadataCache {
  SqliteLibraryMetadataCache._(this._database) {
    _migrate();
  }

  final Database _database;

  static Future<SqliteLibraryMetadataCache> open() async {
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    return SqliteLibraryMetadataCache._(
      sqlite3.open(
        '${support.path}${Platform.pathSeparator}library-cache-v1.sqlite3',
      ),
    );
  }

  static SqliteLibraryMetadataCache inMemory() =>
      SqliteLibraryMetadataCache._(sqlite3.openInMemory());

  void _migrate() {
    if (_database.userVersion > 1) {
      throw StateError(
        'The library cache was created by a newer gaze version.',
      );
    }
    if (_database.userVersion == 0) {
      _database.execute('''
        CREATE TABLE album_pages (
          server_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          sort TEXT NOT NULL,
          start_index INTEGER NOT NULL,
          page_limit INTEGER NOT NULL,
          total_count INTEGER NOT NULL,
          albums_json TEXT NOT NULL,
          stored_at_ms INTEGER NOT NULL,
          PRIMARY KEY (server_id, user_id, sort, start_index, page_limit)
        ) STRICT;
      ''');
      _database.userVersion = 1;
    }
  }

  @override
  Future<CachedAlbumPage?> readAlbumPage(AlbumPageCacheKey key) async {
    final rows = _database.select(
      '''
        SELECT total_count, albums_json, stored_at_ms
        FROM album_pages
        WHERE server_id = ? AND user_id = ? AND sort = ?
          AND start_index = ? AND page_limit = ?
      ''',
      [key.serverId, key.userId, key.sort.name, key.startIndex, key.limit],
    );
    if (rows.isEmpty) {
      return null;
    }
    try {
      final row = rows.single;
      final values = jsonDecode(row['albums_json'] as String) as List;
      final albums = values
          .whereType<Map<String, dynamic>>()
          .map(
            (value) => AlbumSummary(
              id: value['id'] as String,
              title: value['title'] as String,
              artist: value['artist'] as String,
              year: value['year'] as int?,
              imageTag: value['imageTag'] as String?,
            ),
          )
          .toList(growable: false);
      return CachedAlbumPage(
        page: AlbumPage(albums: albums, totalCount: row['total_count'] as int),
        storedAt: DateTime.fromMillisecondsSinceEpoch(
          row['stored_at_ms'] as int,
        ),
      );
    } on FormatException {
      await _deletePage(key);
      return null;
    } on TypeError {
      await _deletePage(key);
      return null;
    }
  }

  @override
  Future<void> writeAlbumPage(AlbumPageCacheKey key, AlbumPage page) async {
    final albums = page.albums
        .map(
          (album) => {
            'id': album.id,
            'title': album.title,
            'artist': album.artist,
            'year': album.year,
            'imageTag': album.imageTag,
          },
        )
        .toList(growable: false);
    _database.execute(
      '''
        INSERT OR REPLACE INTO album_pages (
          server_id, user_id, sort, start_index, page_limit,
          total_count, albums_json, stored_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        key.serverId,
        key.userId,
        key.sort.name,
        key.startIndex,
        key.limit,
        page.totalCount,
        jsonEncode(albums),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> _deletePage(AlbumPageCacheKey key) async {
    _database.execute(
      '''
        DELETE FROM album_pages
        WHERE server_id = ? AND user_id = ? AND sort = ?
          AND start_index = ? AND page_limit = ?
      ''',
      [key.serverId, key.userId, key.sort.name, key.startIndex, key.limit],
    );
  }

  @override
  Future<void> clearServer(String serverId) async {
    _database.execute('DELETE FROM album_pages WHERE server_id = ?', [
      serverId,
    ]);
  }

  Future<void> close() async => _database.close();
}
