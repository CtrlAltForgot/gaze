import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'artwork_cache.dart';

class FileArtworkCache implements RetainedArtworkCache {
  FileArtworkCache({
    required Directory directory,
    this.maximumBytes = 256 * 1024 * 1024,
    this.maximumEntries = 2000,
    this.retainLatest = true,
  }) : _directory = directory;
  final Directory _directory;
  final int maximumBytes;
  final int maximumEntries;
  final bool retainLatest;
  final Map<String, _Entry> _entries = {};
  final Map<String, _Entry> _latest = {};
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  int _serial = 0;

  static Future<FileArtworkCache> open() async {
    final support = await getApplicationSupportDirectory();
    final cache = FileArtworkCache(
      directory: Directory(
        '${support.path}${Platform.pathSeparator}artwork-cache-v1',
      ),
    );
    await cache.initialize();
    return cache;
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    await _directory.create(recursive: true);
    final files = await _directory
        .list()
        .where((file) => file is File && file.path.endsWith('.json'))
        .cast<File>()
        .toList();
    // Index once, instead of rescanning the whole cache after every download.
    for (var offset = 0; offset < files.length; offset += 64) {
      final batch = files.skip(offset).take(64);
      await Future.wait(
        batch.map((file) async {
          try {
            final data =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
            final key = data['key'] as String;
            final parts = key.split('\u0000');
            if (parts.length != 4) return;
            final entry = _Entry(
              key,
              '${parts[0]}\u0000${parts[1]}\u0000${parts[3]}',
              file.path.replaceFirst(RegExp(r'\.json$'), '.art'),
              data['size'] as int,
              data['accessedAt'] as int,
            );
            if (!await File(entry.path).exists()) return;
            _entries[key] = entry;
            if ((_latest[entry.identity]?.accessedAt ?? -1) < entry.accessedAt)
              _latest[entry.identity] = entry;
          } catch (_) {
            /* Ignore a damaged sidecar without losing other images. */
          }
        }),
      );
    }
  }

  String _identity(String server, String itemId, int width) =>
      '$server\u0000$itemId\u0000$width';
  @override
  String? latestPath(String server, String itemId, {int maxWidth = 600}) =>
      _latest[_identity(server, itemId, maxWidth)]?.path;

  @override
  Future<Uint8List?> read(ArtworkCacheKey key) async {
    await initialize();
    return _read(_entries[key.value]);
  }

  @override
  Future<Uint8List?> readLatest(
    String server,
    String itemId, {
    int maxWidth = 600,
  }) async {
    await initialize();
    return _read(_latest[_identity(server, itemId, maxWidth)]);
  }

  Future<Uint8List?> _read(_Entry? entry) async {
    if (entry == null) return null;
    try {
      final bytes = await File(entry.path).readAsBytes();
      if (bytes.isEmpty || bytes.length != entry.size) return null;
      entry.accessedAt = DateTime.now().millisecondsSinceEpoch;
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(ArtworkCacheKey key, Uint8List bytes) {
    final result = _writes.then((_) => _write(key, bytes));
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> _write(ArtworkCacheKey key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maximumBytes) return;
    await initialize();
    final stem = _hash(key.value);
    final data = File('${_directory.path}/$stem.art');
    final metadata = File('${_directory.path}/$stem.json');
    final suffix = '.${DateTime.now().microsecondsSinceEpoch}.${_serial++}.tmp';
    final tempData = File('${data.path}$suffix');
    final tempMetadata = File('${metadata.path}$suffix');
    final entry = _Entry(
      key.value,
      _identity(key.server, key.itemId, key.maxWidth),
      data.path,
      bytes.length,
      DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await tempData.writeAsBytes(bytes);
      await tempMetadata.writeAsString(
        jsonEncode({
          'key': key.value,
          'size': bytes.length,
          'accessedAt': entry.accessedAt,
        }),
      );
      // Rename replaces atomically on the supported desktop filesystems. Keep
      // the old usable image until the complete replacement is on disk.
      await tempData.rename(data.path);
      await tempMetadata.rename(metadata.path);
      _entries[key.value] = entry;
      _latest[entry.identity] = entry;
      await _evict();
    } finally {
      for (final file in [tempData, tempMetadata]) {
        if (await file.exists()) await file.delete();
      }
    }
  }

  Future<void> _evict() async {
    var total = _entries.values.fold<int>(0, (sum, entry) => sum + entry.size);
    var count = _entries.length;
    final oldest = _entries.values.toList()
      ..sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
    for (final entry in oldest) {
      final isLatest = identical(_latest[entry.identity], entry);
      if (retainLatest && isLatest) continue;
      if (!retainLatest && total <= maximumBytes && count <= maximumEntries)
        break;
      await _remove(entry);
      total -= entry.size;
      count--;
    }
  }

  Future<void> _remove(_Entry entry) async {
    for (final path in [
      entry.path,
      entry.path.replaceFirst(RegExp(r'\.art$'), '.json'),
    ]) {
      try {
        await File(path).delete();
      } on FileSystemException {
        /* Already gone. */
      }
    }
    _entries.remove(entry.key);
    if (identical(_latest[entry.identity], entry))
      _latest.remove(entry.identity);
  }
}

class _Entry {
  _Entry(this.key, this.identity, this.path, this.size, this.accessedAt);
  final String key, identity, path;
  final int size;
  int accessedAt;
}

String _hash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
