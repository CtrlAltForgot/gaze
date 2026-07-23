import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/library/album_summary.dart';
import 'package:gaze/storage/library_metadata_cache.dart';
import 'package:gaze/storage/sqlite_library_metadata_cache.dart';

void main() {
  const key = AlbumPageCacheKey(
    serverId: 'server-one',
    userId: 'listener',
    sort: AlbumSort.title,
    startIndex: 0,
    limit: 24,
  );

  test('round-trips metadata without artwork bytes', () async {
    final cache = SqliteLibraryMetadataCache.inMemory();
    await cache.writeAlbumPage(
      key,
      const AlbumPage(
        albums: [
          AlbumSummary(
            id: 'album',
            title: 'Album',
            artist: 'Artist',
            year: 2026,
            imageTag: 'image-version',
          ),
        ],
        totalCount: 31,
      ),
    );

    final cached = await cache.readAlbumPage(key);

    expect(cached, isNotNull);
    expect(cached!.page.totalCount, 31);
    expect(cached.page.albums.single.title, 'Album');
    expect(cached.page.albums.single.imageTag, 'image-version');
    expect(cached.page.albums.single.artworkBytes, isNull);
    expect(cached.isFreshAt(DateTime.now()), isTrue);
    await cache.close();
  });

  test('separates server, user, sort, and page queries', () async {
    final cache = SqliteLibraryMetadataCache.inMemory();
    await cache.writeAlbumPage(key, const AlbumPage(albums: [], totalCount: 0));

    expect(
      await cache.readAlbumPage(
        const AlbumPageCacheKey(
          serverId: 'server-two',
          userId: 'listener',
          sort: AlbumSort.title,
          startIndex: 0,
          limit: 24,
        ),
      ),
      isNull,
    );
    expect(
      await cache.readAlbumPage(
        const AlbumPageCacheKey(
          serverId: 'server-one',
          userId: 'listener',
          sort: AlbumSort.artist,
          startIndex: 0,
          limit: 24,
        ),
      ),
      isNull,
    );
    await cache.close();
  });

  test('replaces a page atomically and clears one server', () async {
    final cache = SqliteLibraryMetadataCache.inMemory();
    await cache.writeAlbumPage(
      key,
      const AlbumPage(
        albums: [AlbumSummary(id: 'old', title: 'Old', artist: 'Artist')],
        totalCount: 1,
      ),
    );
    await cache.writeAlbumPage(
      key,
      const AlbumPage(
        albums: [AlbumSummary(id: 'new', title: 'New', artist: 'Artist')],
        totalCount: 1,
      ),
    );

    expect((await cache.readAlbumPage(key))!.page.albums.single.id, 'new');
    await cache.clearServer('server-one');
    expect(await cache.readAlbumPage(key), isNull);
    await cache.close();
  });

  test('freshness distinguishes reusable and stale snapshots', () {
    final cached = CachedAlbumPage(
      page: const AlbumPage(albums: [], totalCount: 0),
      storedAt: DateTime(2026, 1, 1, 12),
    );

    expect(cached.isFreshAt(DateTime(2026, 1, 1, 12, 14)), isTrue);
    expect(cached.isFreshAt(DateTime(2026, 1, 1, 12, 16)), isFalse);
  });
}
