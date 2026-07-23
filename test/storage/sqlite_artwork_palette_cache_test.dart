import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/storage/artwork_palette_cache.dart';
import 'package:gaze/storage/sqlite_artwork_palette_cache.dart';

void main() {
  test('round-trips a four-color artwork palette', () async {
    final cache = SqliteArtworkPaletteCache.inMemory();
    const palette = StoredArtworkPalette(
      accentArgb: 0xFFCC3355,
      backgroundArgb: [0xFF221122, 0xFF332233, 0xFF443344, 0xFF554455],
    );

    await cache.write('artwork-one', palette);
    final restored = await cache.read('artwork-one');

    expect(restored, isNotNull);
    expect(restored!.accentArgb, palette.accentArgb);
    expect(restored.backgroundArgb, palette.backgroundArgb);
    expect(await cache.read('artwork-two'), isNull);
    await cache.close();
  });

  test('artwork fingerprints are stable and content-sensitive', () {
    final first = fingerprintArtwork(Uint8List.fromList([1, 2, 3]));
    final same = fingerprintArtwork(Uint8List.fromList([1, 2, 3]));
    final changed = fingerprintArtwork(Uint8List.fromList([1, 2, 4]));

    expect(first, same);
    expect(changed, isNot(first));
  });

  test('rejects incomplete palettes', () async {
    final cache = SqliteArtworkPaletteCache.inMemory();

    await expectLater(
      cache.write(
        'artwork',
        const StoredArtworkPalette(
          accentArgb: 0xFFFFFFFF,
          backgroundArgb: [0xFF000000],
        ),
      ),
      throwsArgumentError,
    );
    await cache.close();
  });
}
