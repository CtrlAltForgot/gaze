import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class ArtworkPalette {
  const ArtworkPalette({required this.accent, required this.background});

  static const fallback = ArtworkPalette(
    accent: Color(0xFFB78CFF),
    background: [Color(0xFF2B2038), Color(0xFF202431), Color(0xFF241F30)],
  );

  final Color accent;
  final List<Color> background;
}

Future<ArtworkPalette> extractArtworkPalette(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: 48,
    targetHeight: 48,
  );
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  if (data == null) {
    return ArtworkPalette.fallback;
  }
  final colors = <Color>[];
  for (var offset = 0; offset + 3 < data.lengthInBytes; offset += 16) {
    if (data.getUint8(offset + 3) < 180) {
      continue;
    }
    colors.add(
      Color.fromARGB(
        255,
        data.getUint8(offset),
        data.getUint8(offset + 1),
        data.getUint8(offset + 2),
      ),
    );
  }
  return deriveArtworkPalette(colors);
}

ArtworkPalette deriveArtworkPalette(List<Color> samples) {
  if (samples.isEmpty) {
    return ArtworkPalette.fallback;
  }
  final buckets = <int, List<double>>{};
  for (final color in samples) {
    final hsv = HSVColor.fromColor(color);
    final key =
        ((hsv.hue / 24).round() % 15) * 100 +
        (hsv.saturation * 3).floor() * 10 +
        (hsv.value * 3).floor();
    final bucket = buckets.putIfAbsent(key, () => [0, 0, 0, 0]);
    bucket[0]++;
    bucket[1] += color.r;
    bucket[2] += color.g;
    bucket[3] += color.b;
  }
  final candidates = buckets.values
      .map(
        (bucket) => Color.from(
          alpha: 1,
          red: bucket[1] / bucket[0],
          green: bucket[2] / bucket[0],
          blue: bucket[3] / bucket[0],
        ),
      )
      .toList();
  candidates.sort((a, b) {
    final aHsv = HSVColor.fromColor(a);
    final bHsv = HSVColor.fromColor(b);
    final aScore = aHsv.saturation * .7 + aHsv.value * .3;
    final bScore = bHsv.saturation * .7 + bHsv.value * .3;
    return bScore.compareTo(aScore);
  });

  final chromatic = candidates.where(
    (color) => HSVColor.fromColor(color).saturation >= .12,
  );
  final accentSource = chromatic.isEmpty ? candidates.first : chromatic.first;
  final sourceHsv = HSVColor.fromColor(accentSource);
  final accent = chromatic.isEmpty
      ? sourceHsv
            .withSaturation(0)
            .withValue(sourceHsv.value.clamp(.5, .78))
            .toColor()
      : sourceHsv
            .withSaturation(sourceHsv.saturation.clamp(.28, .88))
            .withValue(sourceHsv.value.clamp(.62, .9))
            .toColor();

  final background = <Color>[];
  for (final candidate in candidates) {
    final hsv = HSVColor.fromColor(candidate);
    final fitted = hsv
        .withSaturation(hsv.saturation.clamp(0, .82))
        .withValue(hsv.value.clamp(.18, .44))
        .toColor();
    if (background.every(
      (existing) => (HSVColor.fromColor(existing).hue - hsv.hue).abs() > 18,
    )) {
      background.add(fitted);
    }
    if (background.length == 2) {
      break;
    }
  }
  while (background.length < 2) {
    background.add(
      background.isEmpty ? const Color(0xFF242833) : background[0],
    );
  }
  final blended = Color.lerp(background[0], background[1], .5)!;
  final blendedHsv = HSVColor.fromColor(blended);
  return ArtworkPalette(
    accent: accent,
    background: [
      ...background,
      blendedHsv
          .withSaturation(blendedHsv.saturation.clamp(.08, .68))
          .withValue(blendedHsv.value.clamp(.2, .34))
          .toColor(),
    ],
  );
}
