import 'dart:typed_data';

class ArtworkCacheKey {
  const ArtworkCacheKey({
    required this.server,
    required this.itemId,
    required this.imageTag,
    required this.maxWidth,
  });

  final String server;
  final String itemId;
  final String imageTag;
  final int maxWidth;

  String get value => '$server\u0000$itemId\u0000$imageTag\u0000$maxWidth';
}

abstract interface class ArtworkCache {
  Future<Uint8List?> read(ArtworkCacheKey key);

  Future<void> write(ArtworkCacheKey key, Uint8List bytes);
}

class DisabledArtworkCache implements ArtworkCache {
  const DisabledArtworkCache();

  @override
  Future<Uint8List?> read(ArtworkCacheKey key) async => null;

  @override
  Future<void> write(ArtworkCacheKey key, Uint8List bytes) async {}
}
