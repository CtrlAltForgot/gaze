import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'artwork_cache.dart';

class FileArtworkCache implements ArtworkCache {
  FileArtworkCache({
    required Directory directory,
    this.maximumBytes = 256 * 1024 * 1024,
    this.maximumEntries = 2000,
  }) : _directory = directory;

  final Directory _directory;
  final int maximumBytes;
  final int maximumEntries;

  static Future<FileArtworkCache> open() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}artwork-cache-v1',
    );
    await directory.create(recursive: true);
    return FileArtworkCache(directory: directory);
  }

  @override
  Future<Uint8List?> read(ArtworkCacheKey key) async {
    final stem = _hash(key.value);
    final dataFile = File('${_directory.path}/$stem.art');
    final metadataFile = File('${_directory.path}/$stem.json');
    try {
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      if (metadata['key'] != key.value) {
        return null;
      }
      final bytes = await dataFile.readAsBytes();
      if (bytes.isEmpty || metadata['size'] != bytes.length) {
        await _remove(dataFile, metadataFile);
        return null;
      }
      metadata['accessedAt'] = DateTime.now().millisecondsSinceEpoch;
      await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
      return bytes;
    } on FileSystemException {
      return null;
    } on FormatException {
      await _remove(dataFile, metadataFile);
      return null;
    } on TypeError {
      await _remove(dataFile, metadataFile);
      return null;
    }
  }

  @override
  Future<void> write(ArtworkCacheKey key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maximumBytes) {
      return;
    }
    await _directory.create(recursive: true);
    final stem = _hash(key.value);
    final dataFile = File('${_directory.path}/$stem.art');
    final metadataFile = File('${_directory.path}/$stem.json');
    final temporaryData = File('${dataFile.path}.tmp');
    final temporaryMetadata = File('${metadataFile.path}.tmp');
    await temporaryData.writeAsBytes(bytes, flush: true);
    await temporaryMetadata.writeAsString(
      jsonEncode({
        'key': key.value,
        'size': bytes.length,
        'accessedAt': DateTime.now().millisecondsSinceEpoch,
      }),
      flush: true,
    );
    if (await dataFile.exists()) {
      await dataFile.delete();
    }
    if (await metadataFile.exists()) {
      await metadataFile.delete();
    }
    await temporaryData.rename(dataFile.path);
    await temporaryMetadata.rename(metadataFile.path);
    await _evict();
  }

  Future<void> _evict() async {
    final entries = <({File data, File metadata, int size, int accessedAt})>[];
    await for (final entity in _directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        final metadata =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final data = File(entity.path.replaceFirst(RegExp(r'\.json$'), '.art'));
        entries.add((
          data: data,
          metadata: entity,
          size: metadata['size'] as int,
          accessedAt: metadata['accessedAt'] as int,
        ));
      } catch (_) {
        await entity.delete();
      }
    }
    entries.sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
    var totalBytes = entries.fold<int>(0, (sum, entry) => sum + entry.size);
    var totalEntries = entries.length;
    for (final entry in entries) {
      if (totalBytes <= maximumBytes && totalEntries <= maximumEntries) {
        break;
      }
      await _remove(entry.data, entry.metadata);
      totalBytes -= entry.size;
      totalEntries--;
    }
  }

  Future<void> _remove(File data, File metadata) async {
    for (final file in [data, metadata]) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // A broken cache entry is equivalent to a miss.
      }
    }
  }
}

String _hash(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
