import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/song_summary.dart';
import '../library/track_summary.dart';
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
    if (_database.userVersion > 3) {
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
    if (_database.userVersion == 1) {
      _database.execute('''
        CREATE TABLE song_libraries (
          server_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          total_count INTEGER NOT NULL,
          songs_json TEXT NOT NULL,
          stored_at_ms INTEGER NOT NULL,
          PRIMARY KEY (server_id, user_id)
        ) STRICT;
      ''');
      _database.userVersion = 2;
    }
    if (_database.userVersion == 2) {
      _database.execute(
        'CREATE TABLE artist_pages (server_id TEXT NOT NULL,user_id TEXT NOT NULL,start_index INTEGER NOT NULL,page_limit INTEGER NOT NULL,total_count INTEGER NOT NULL,artists_json TEXT NOT NULL,stored_at_ms INTEGER NOT NULL,PRIMARY KEY(server_id,user_id,start_index,page_limit)) STRICT',
      );
      _database.userVersion = 3;
    }
  }

  @override
  Future<CachedArtistPage?> readArtistPage(ArtistPageCacheKey key) async {
    final rows = _database.select(
      'SELECT * FROM artist_pages WHERE server_id=? AND user_id=? AND start_index=? AND page_limit=?',
      [key.serverId, key.userId, key.startIndex, key.limit],
    );
    if (rows.isEmpty) return null;
    try {
      final row = rows.single;
      final values = jsonDecode(row['artists_json'] as String) as List;
      return CachedArtistPage(
        page: ArtistPage(
          artists: values
              .map(
                (value) => ArtistSummary(
                  id: value['id'] as String,
                  name: value['name'] as String,
                  imageTag: value['imageTag'] as String?,
                ),
              )
              .toList(),
          totalCount: row['total_count'] as int,
        ),
        storedAt: DateTime.fromMillisecondsSinceEpoch(
          row['stored_at_ms'] as int,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeArtistPage(ArtistPageCacheKey key, ArtistPage page) async {
    _database.execute(
      'INSERT OR REPLACE INTO artist_pages VALUES (?,?,?,?,?,?,?)',
      [
        key.serverId,
        key.userId,
        key.startIndex,
        key.limit,
        page.totalCount,
        jsonEncode(
          page.artists
              .map(
                (artist) => {
                  'id': artist.id,
                  'name': artist.name,
                  'imageTag': artist.imageTag,
                },
              )
              .toList(),
        ),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
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
  Future<CachedSongLibrary?> readSongs(SongLibraryCacheKey key) async {
    final rows = _database.select(
      '''
        SELECT total_count, songs_json, stored_at_ms
        FROM song_libraries
        WHERE server_id = ? AND user_id = ?
      ''',
      [key.serverId, key.userId],
    );
    if (rows.isEmpty) {
      return null;
    }
    try {
      final row = rows.single;
      final values = jsonDecode(row['songs_json'] as String) as List;
      final songs = values
          .whereType<Map<String, dynamic>>()
          .map(
            (value) => SongSummary(
              track: TrackSummary(
                id: value['id'] as String,
                title: value['title'] as String,
                artist: value['artist'] as String,
                duration: Duration(milliseconds: value['durationMs'] as int),
                trackNumber: value['trackNumber'] as int?,
                discNumber: value['discNumber'] as int?,
              ),
              album: value['album'] as String,
              albumId: value['albumId'] as String?,
              imageTag: value['imageTag'] as String?,
            ),
          )
          .toList(growable: false);
      return CachedSongLibrary(
        page: SongPage(songs: songs, totalCount: row['total_count'] as int),
        storedAt: DateTime.fromMillisecondsSinceEpoch(
          row['stored_at_ms'] as int,
        ),
      );
    } on FormatException {
      await _deleteSongs(key);
      return null;
    } on TypeError {
      await _deleteSongs(key);
      return null;
    }
  }

  @override
  Future<void> writeSongs(SongLibraryCacheKey key, SongPage page) async {
    final songs = page.songs
        .map(
          (song) => {
            'id': song.track.id,
            'title': song.track.title,
            'artist': song.track.artist,
            'durationMs': song.track.duration.inMilliseconds,
            'trackNumber': song.track.trackNumber,
            'discNumber': song.track.discNumber,
            'album': song.album,
            'albumId': song.albumId,
            'imageTag': song.imageTag,
          },
        )
        .toList(growable: false);
    _database.execute(
      '''
        INSERT OR REPLACE INTO song_libraries (
          server_id, user_id, total_count, songs_json, stored_at_ms
        ) VALUES (?, ?, ?, ?, ?)
      ''',
      [
        key.serverId,
        key.userId,
        page.totalCount,
        jsonEncode(songs),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> _deleteSongs(SongLibraryCacheKey key) async {
    _database.execute(
      'DELETE FROM song_libraries WHERE server_id = ? AND user_id = ?',
      [key.serverId, key.userId],
    );
  }

  @override
  Future<void> clearServer(String serverId) async {
    _database.execute('DELETE FROM artist_pages WHERE server_id = ?', [
      serverId,
    ]);
    _database.execute('DELETE FROM album_pages WHERE server_id = ?', [
      serverId,
    ]);
    _database.execute('DELETE FROM song_libraries WHERE server_id = ?', [
      serverId,
    ]);
  }

  Future<void> close() async => _database.close();
}
