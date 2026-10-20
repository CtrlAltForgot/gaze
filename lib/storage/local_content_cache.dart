import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

abstract interface class LocalContentCache {
  Future<String?> read(String key);
  Future<void> write(
    String key,
    String value, {
    Duration ttl = const Duration(days: 30),
  });
}

class DisabledLocalContentCache implements LocalContentCache {
  const DisabledLocalContentCache();
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(
    String key,
    String value, {
    Duration ttl = const Duration(days: 30),
  }) async {}
}

/// Local, bounded metadata only. Never stores credentials or streaming URLs.
class SqliteLocalContentCache implements LocalContentCache {
  SqliteLocalContentCache._(this._db) {
    _db.execute(
      'CREATE TABLE IF NOT EXISTS content (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires INTEGER NOT NULL, touched INTEGER NOT NULL)',
    );
  }
  final Database _db;
  static Future<SqliteLocalContentCache> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return SqliteLocalContentCache._(
      sqlite3.open(
        '${dir.path}${Platform.pathSeparator}content-cache-v1.sqlite3',
      ),
    );
  }

  static SqliteLocalContentCache inMemory() =>
      SqliteLocalContentCache._(sqlite3.openInMemory());
  @override
  Future<String?> read(String key) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = _db.select(
      'SELECT value FROM content WHERE key=? AND expires>?',
      [key, now],
    );
    if (rows.isEmpty) return null;
    _db.execute('UPDATE content SET touched=? WHERE key=?', [now, key]);
    return rows.single['value'] as String;
  }

  @override
  Future<void> write(
    String key,
    String value, {
    Duration ttl = const Duration(days: 30),
  }) async {
    if (value.length > 4 * 1024 * 1024) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('INSERT OR REPLACE INTO content VALUES (?,?,?,?)', [
      key,
      value,
      now + ttl.inMilliseconds,
      now,
    ]);
    _db.execute('DELETE FROM content WHERE expires<=?', [now]);
    _db.execute(
      'DELETE FROM content WHERE key NOT IN (SELECT key FROM content ORDER BY touched DESC LIMIT 512)',
    );
    while ((_db
                .select(
                  'SELECT COALESCE(SUM(length(value)),0) AS size FROM content',
                )
                .single['size']
            as int) >
        64 * 1024 * 1024) {
      _db.execute(
        'DELETE FROM content WHERE key=(SELECT key FROM content ORDER BY touched LIMIT 1)',
      );
    }
  }

  void dispose() => _db.close();
}
