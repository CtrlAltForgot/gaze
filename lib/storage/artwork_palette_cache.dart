import 'dart:typed_data';

class StoredArtworkPalette {
  const StoredArtworkPalette({
    required this.accentArgb,
    required this.backgroundArgb,
    required this.backgroundWeights,
  });

  final int accentArgb;
  final List<int> backgroundArgb;
  final List<double> backgroundWeights;
}

abstract interface class ArtworkPaletteCache {
  Future<StoredArtworkPalette?> read(String artworkFingerprint);

  Future<void> write(String artworkFingerprint, StoredArtworkPalette palette);
}

class DisabledArtworkPaletteCache implements ArtworkPaletteCache {
  const DisabledArtworkPaletteCache();

  @override
  Future<StoredArtworkPalette?> read(String artworkFingerprint) async => null;

  @override
  Future<void> write(
    String artworkFingerprint,
    StoredArtworkPalette palette,
  ) async {}
}

String fingerprintArtwork(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
