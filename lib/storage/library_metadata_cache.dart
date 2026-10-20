import '../library/album_summary.dart';
import '../library/artist_summary.dart';
import '../library/song_summary.dart';

class AlbumPageCacheKey {
  const AlbumPageCacheKey({
    required this.serverId,
    required this.userId,
    required this.sort,
    required this.startIndex,
    required this.limit,
  });

  final String serverId;
  final String userId;
  final AlbumSort sort;
  final int startIndex;
  final int limit;
}

class CachedAlbumPage {
  const CachedAlbumPage({required this.page, required this.storedAt});

  final AlbumPage page;
  final DateTime storedAt;

  bool isFreshAt(
    DateTime now, {
    Duration maxAge = const Duration(minutes: 15),
  }) {
    final age = now.difference(storedAt);
    return !age.isNegative && age <= maxAge;
  }
}

class SongLibraryCacheKey {
  const SongLibraryCacheKey({required this.serverId, required this.userId});

  final String serverId;
  final String userId;
}

class CachedSongLibrary {
  const CachedSongLibrary({required this.page, required this.storedAt});

  final SongPage page;
  final DateTime storedAt;
}

class ArtistPageCacheKey {
  const ArtistPageCacheKey({
    required this.serverId,
    required this.userId,
    required this.startIndex,
    required this.limit,
  });
  final String serverId, userId;
  final int startIndex, limit;
}

class CachedArtistPage {
  const CachedArtistPage({required this.page, required this.storedAt});
  final ArtistPage page;
  final DateTime storedAt;
}

abstract interface class LibraryMetadataCache {
  Future<CachedArtistPage?> readArtistPage(ArtistPageCacheKey key);
  Future<void> writeArtistPage(ArtistPageCacheKey key, ArtistPage page);

  Future<CachedAlbumPage?> readAlbumPage(AlbumPageCacheKey key);

  Future<void> writeAlbumPage(AlbumPageCacheKey key, AlbumPage page);

  Future<CachedSongLibrary?> readSongs(SongLibraryCacheKey key);

  Future<void> writeSongs(SongLibraryCacheKey key, SongPage page);

  Future<void> clearServer(String serverId);
}

class DisabledLibraryMetadataCache implements LibraryMetadataCache {
  const DisabledLibraryMetadataCache();
  @override
  Future<CachedArtistPage?> readArtistPage(ArtistPageCacheKey key) async =>
      null;
  @override
  Future<void> writeArtistPage(ArtistPageCacheKey key, ArtistPage page) async {}

  @override
  Future<CachedAlbumPage?> readAlbumPage(AlbumPageCacheKey key) async => null;

  @override
  Future<void> writeAlbumPage(AlbumPageCacheKey key, AlbumPage page) async {}

  @override
  Future<CachedSongLibrary?> readSongs(SongLibraryCacheKey key) async => null;

  @override
  Future<void> writeSongs(SongLibraryCacheKey key, SongPage page) async {}

  @override
  Future<void> clearServer(String serverId) async {}
}
