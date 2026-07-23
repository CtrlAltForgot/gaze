import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'artwork_palette_cache.dart';

class SqliteArtworkPaletteCache implements ArtworkPaletteCache {
  SqliteArtworkPaletteCache._(this._database) {
    _migrate();
  }

  final Database _database;

  static Future<SqliteArtworkPaletteCache> open() async {
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    return SqliteArtworkPaletteCache._(
      sqlite3.open(
        '${support.path}${Platform.pathSeparator}palette-cache-v1.sqlite3',
      ),
    );
  }

  static SqliteArtworkPaletteCache inMemory() =>
      SqliteArtworkPaletteCache._(sqlite3.openInMemory());

  void _migrate() {
    if (_database.userVersion > 1) {
      throw StateError(
        'The palette cache was created by a newer gaze version.',
      );
    }
    if (_database.userVersion == 0) {
      _database.execute('''
        CREATE TABLE artwork_palettes (
          artwork_fingerprint TEXT NOT NULL PRIMARY KEY,
          accent_argb INTEGER NOT NULL,
          background_json TEXT NOT NULL,
          updated_at_ms INTEGER NOT NULL
        ) STRICT;
      ''');
      _database.userVersion = 1;
    }
  }

  @override
  Future<StoredArtworkPalette?> read(String artworkFingerprint) async {
    final rows = _database.select(
      '''
        SELECT accent_argb, background_json
        FROM artwork_palettes
        WHERE artwork_fingerprint = ?
      ''',
      [artworkFingerprint],
    );
    if (rows.isEmpty) {
      return null;
    }
    try {
      final row = rows.single;
      final background = (jsonDecode(row['background_json'] as String) as List)
          .cast<int>();
      if (background.length != 4) {
        await _delete(artworkFingerprint);
        return null;
      }
      return StoredArtworkPalette(
        accentArgb: row['accent_argb'] as int,
        backgroundArgb: List.unmodifiable(background),
      );
    } on FormatException {
      await _delete(artworkFingerprint);
      return null;
    } on TypeError {
      await _delete(artworkFingerprint);
      return null;
    }
  }

  @override
  Future<void> write(
    String artworkFingerprint,
    StoredArtworkPalette palette,
  ) async {
    if (palette.backgroundArgb.length != 4) {
      throw ArgumentError.value(
        palette.backgroundArgb,
        'palette.backgroundArgb',
        'An artwork palette must contain four background colors.',
      );
    }
    _database.execute(
      '''
        INSERT OR REPLACE INTO artwork_palettes (
          artwork_fingerprint, accent_argb, background_json, updated_at_ms
        ) VALUES (?, ?, ?, ?)
      ''',
      [
        artworkFingerprint,
        palette.accentArgb,
        jsonEncode(palette.backgroundArgb),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> _delete(String artworkFingerprint) async {
    _database.execute(
      'DELETE FROM artwork_palettes WHERE artwork_fingerprint = ?',
      [artworkFingerprint],
    );
  }

  Future<void> close() async => _database.close();
}
