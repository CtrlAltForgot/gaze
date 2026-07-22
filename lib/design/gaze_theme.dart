import 'package:flutter/material.dart';

abstract final class GazeColors {
  static const canvas = Color(0xFF101114);
  static const navigation = Color(0xFF16171B);
  static const surface = Color(0xFF1D1F24);
  static const surfaceRaised = Color(0xFF252830);
  static const outline = Color(0xFF30333B);
  static const textPrimary = Color(0xFFF4F1EA);
  static const textSecondary = Color(0xFFA9ABB3);
  static const accent = Color(0xFFB7A5FF);
}

abstract final class GazeSpacing {
  static const xSmall = 4.0;
  static const small = 8.0;
  static const medium = 16.0;
  static const large = 24.0;
  static const xLarge = 32.0;
  static const xxLarge = 48.0;
}

abstract final class GazeRadii {
  static const control = 10.0;
  static const card = 16.0;
}

ThemeData buildGazeTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: GazeColors.accent,
    brightness: Brightness.dark,
    surface: GazeColors.surface,
  );

  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: GazeColors.canvas,
    fontFamily: 'sans-serif',
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        color: GazeColors.textPrimary,
        fontSize: 36,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
      ),
      headlineSmall: TextStyle(
        color: GazeColors.textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
      ),
      titleMedium: TextStyle(
        color: GazeColors.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: TextStyle(
        color: GazeColors.textSecondary,
        fontSize: 14,
        height: 1.4,
      ),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: GazeColors.accent),
    focusColor: GazeColors.accent.withValues(alpha: 0.22),
    splashFactory: InkSparkle.splashFactory,
  );
}
