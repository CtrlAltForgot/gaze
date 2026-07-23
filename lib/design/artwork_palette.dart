import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class ArtworkPalette {
  const ArtworkPalette({
    required this.accent,
    required this.background,
    required this.backgroundWeights,
  });

  static const fallback = ArtworkPalette(
    accent: Color(0xFFB78CFF),
    background: [
      Color(0xFF2B2038),
      Color(0xFF202431),
      Color(0xFF30213A),
      Color(0xFF241F30),
    ],
    backgroundWeights: [.42, .28, .18, .12],
  );

  final Color accent;
  final List<Color> background;
  final List<double> backgroundWeights;
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
        (bucket) => (
          color: Color.from(
            alpha: 1,
            red: bucket[1] / bucket[0],
            green: bucket[2] / bucket[0],
            blue: bucket[3] / bucket[0],
          ),
          population: bucket[0] / samples.length,
        ),
      )
      .toList();
  candidates.sort((a, b) {
    final aHsv = HSVColor.fromColor(a.color);
    final bHsv = HSVColor.fromColor(b.color);
    final aScore =
        a.population * 2.4 + aHsv.saturation * .42 + aHsv.value * .08;
    final bScore =
        b.population * 2.4 + bHsv.saturation * .42 + bHsv.value * .08;
    return bScore.compareTo(aScore);
  });

  final chromaticShare =
      samples
          .where(
            (color) =>
                HSVColor.fromColor(color).saturation >= .12 &&
                HSVColor.fromColor(color).value >= .12,
          )
          .length /
      samples.length;
  final useChromaticPalette = chromaticShare >= .08;
  final chromatic = candidates.where(
    (candidate) => HSVColor.fromColor(candidate.color).saturation >= .12,
  );
  final accentSource = useChromaticPalette && chromatic.isNotEmpty
      ? chromatic.first.color
      : candidates.first.color;
  final sourceHsv = HSVColor.fromColor(accentSource);
  final accent = !useChromaticPalette || chromatic.isEmpty
      ? sourceHsv
            .withSaturation(0)
            .withValue(sourceHsv.value.clamp(.5, .78))
            .toColor()
      : sourceHsv
            .withSaturation(sourceHsv.saturation.clamp(.28, .88))
            .withValue(sourceHsv.value.clamp(.63, .9))
            .toColor();

  final background = <Color>[];
  final backgroundWeights = <double>[];
  for (final candidate in candidates) {
    final hsv = HSVColor.fromColor(candidate.color);
    final fitted = hsv
        .withSaturation(useChromaticPalette ? hsv.saturation.clamp(0, .82) : 0)
        .withValue(hsv.value.clamp(.18, .44))
        .toColor();
    if (background.every(
      (existing) => (HSVColor.fromColor(existing).hue - hsv.hue).abs() > 18,
    )) {
      background.add(fitted);
      backgroundWeights.add(candidate.population);
    }
    if (background.length == 4) {
      break;
    }
  }
  while (background.length < 4) {
    background.add(
      background.isEmpty ? const Color(0xFF242833) : background[0],
    );
    backgroundWeights.add(0);
  }
  final selectedTotal = backgroundWeights.fold<double>(
    0,
    (sum, weight) => sum + weight,
  );
  return ArtworkPalette(
    accent: accent,
    background: background,
    backgroundWeights: selectedTotal <= 0
        ? const [.25, .25, .25, .25]
        : backgroundWeights
              .map((weight) => weight / selectedTotal)
              .toList(growable: false),
  );
}
