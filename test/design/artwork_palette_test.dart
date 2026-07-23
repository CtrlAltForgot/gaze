import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaze/design/artwork_palette.dart';

void main() {
  test('prefers a colorful artwork accent and darkens background colors', () {
    final palette = deriveArtworkPalette([
      ...List.filled(20, const Color(0xFF101015)),
      ...List.filled(8, const Color(0xFFCC294F)),
      ...List.filled(5, const Color(0xFF305FC9)),
    ]);

    final accent = HSVColor.fromColor(palette.accent);
    expect(accent.saturation, greaterThan(.25));
    expect(accent.value, greaterThanOrEqualTo(.62));
    expect(
      palette.background.every(
        (color) => HSVColor.fromColor(color).value <= .44,
      ),
      isTrue,
    );
  });

  test('handles monochrome artwork without forcing a brand color', () {
    final palette = deriveArtworkPalette([
      const Color(0xFF111111),
      const Color(0xFFEEEEEE),
      const Color(0xFF777777),
    ]);

    expect(HSVColor.fromColor(palette.accent).saturation, lessThan(.1));
    expect(palette.background, hasLength(4));
  });

  test('does not let a tiny colorful detail dominate neutral artwork', () {
    final palette = deriveArtworkPalette([
      ...List.filled(70, const Color(0xFF111111)),
      ...List.filled(25, const Color(0xFFE8E8E8)),
      ...List.filled(5, const Color(0xFFE06A20)),
    ]);

    expect(HSVColor.fromColor(palette.accent).saturation, lessThan(.1));
    expect(
      palette.background.every(
        (color) => HSVColor.fromColor(color).saturation < .1,
      ),
      isTrue,
    );
  });

  test('uses a stable fallback without artwork samples', () {
    expect(
      deriveArtworkPalette(const []).accent,
      ArtworkPalette.fallback.accent,
    );
  });
}
