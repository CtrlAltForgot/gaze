import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/storage/artwork_cache.dart';
import 'package:gaze/storage/file_artwork_cache.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gaze-artwork-cache-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  const first = ArtworkCacheKey(
    server: 'server-one',
    itemId: 'album',
    imageTag: 'version-one',
    maxWidth: 600,
  );

  test('round-trips artwork under its complete versioned key', () async {
    final cache = FileArtworkCache(directory: directory);
    await cache.write(first, Uint8List.fromList([1, 2, 3]));

    expect(await cache.read(first), [1, 2, 3]);
    expect(
      await cache.read(
        const ArtworkCacheKey(
          server: 'server-two',
          itemId: 'album',
          imageTag: 'version-one',
          maxWidth: 600,
        ),
      ),
      isNull,
    );
  });

  test('a changed image tag does not return stale artwork', () async {
    final cache = FileArtworkCache(directory: directory);
    await cache.write(first, Uint8List.fromList([1]));

    expect(
      await cache.read(
        const ArtworkCacheKey(
          server: 'server-one',
          itemId: 'album',
          imageTag: 'version-two',
          maxWidth: 600,
        ),
      ),
      isNull,
    );
  });

  test('evicts the least recently used entry to stay bounded', () async {
    final cache = FileArtworkCache(
      directory: directory,
      maximumBytes: 4,
      maximumEntries: 2,
      retainLatest: false,
    );
    await cache.write(first, Uint8List.fromList([1, 2]));
    await Future<void>.delayed(const Duration(milliseconds: 2));
    const second = ArtworkCacheKey(
      server: 'server-one',
      itemId: 'second',
      imageTag: 'v1',
      maxWidth: 600,
    );
    await cache.write(second, Uint8List.fromList([3, 4]));
    await cache.read(second);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    const third = ArtworkCacheKey(
      server: 'server-one',
      itemId: 'third',
      imageTag: 'v1',
      maxWidth: 600,
    );
    await cache.write(third, Uint8List.fromList([5, 6]));

    expect(await cache.read(first), isNull);
    expect(await cache.read(second), [3, 4]);
    expect(await cache.read(third), [5, 6]);
  });

  test('treats damaged metadata as a cache miss', () async {
    final cache = FileArtworkCache(directory: directory);
    await cache.write(first, Uint8List.fromList([1, 2, 3]));
    final metadata = directory.listSync().whereType<File>().singleWhere(
      (file) => file.path.endsWith('.json'),
    );
    await metadata.writeAsString('{broken');

    expect(await FileArtworkCache(directory: directory).read(first), isNull);
  });
  test(
    'retains a latest image for every item across capacity pressure and restart',
    () async {
      final cache = FileArtworkCache(
        directory: directory,
        maximumBytes: 4,
        maximumEntries: 1,
      );
      await cache.write(first, Uint8List.fromList([1, 2, 3]));
      const second = ArtworkCacheKey(
        server: 'server-one',
        itemId: 'artist',
        imageTag: 'v1',
        maxWidth: 600,
      );
      await cache.write(second, Uint8List.fromList([4, 5, 6]));
      final restarted = FileArtworkCache(
        directory: directory,
        maximumBytes: 4,
        maximumEntries: 1,
      );
      await restarted.initialize();
      expect(await restarted.readLatest('server-one', 'album'), [1, 2, 3]);
      expect(await restarted.readLatest('server-one', 'artist'), [4, 5, 6]);
      expect(restarted.latestPath('server-one', 'album'), isNotNull);
      expect(await restarted.readLatest('server-two', 'album'), isNull);
    },
  );
  test(
    'replaces the latest version only after a complete new image is written',
    () async {
      final cache = FileArtworkCache(directory: directory);
      await cache.write(first, Uint8List.fromList([1, 2, 3]));
      const next = ArtworkCacheKey(
        server: 'server-one',
        itemId: 'album',
        imageTag: 'v2',
        maxWidth: 600,
      );
      expect(await cache.read(next), isNull);
      expect(await cache.readLatest('server-one', 'album'), [1, 2, 3]);
      await cache.write(next, Uint8List.fromList([4, 5, 6]));
      expect(await cache.readLatest('server-one', 'album'), [4, 5, 6]);
      expect(await cache.read(first), isNull);
      expect(
        directory.listSync().where((file) => file.path.endsWith('.art')),
        hasLength(1),
      );
    },
  );
}
