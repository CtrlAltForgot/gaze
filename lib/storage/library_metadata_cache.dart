import '../library/album_summary.dart';

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

abstract interface class LibraryMetadataCache {
  Future<CachedAlbumPage?> readAlbumPage(AlbumPageCacheKey key);

  Future<void> writeAlbumPage(AlbumPageCacheKey key, AlbumPage page);

  Future<void> clearServer(String serverId);
}

class DisabledLibraryMetadataCache implements LibraryMetadataCache {
  const DisabledLibraryMetadataCache();

  @override
  Future<CachedAlbumPage?> readAlbumPage(AlbumPageCacheKey key) async => null;

  @override
  Future<void> writeAlbumPage(AlbumPageCacheKey key, AlbumPage page) async {}

  @override
  Future<void> clearServer(String serverId) async {}
}
