import 'package:flutter/material.dart';

/// Colours and sizes of the viewfinder. Everything that draws on top of the camera picture takes
/// its look from here instead of hard-coding values.
abstract final class Viewfinder {
  /// Behind and around the camera picture.
  static const Color background = Color(0xFF000000);

  /// Icons and text over the picture. White on the dark scrims below is well above 4.5:1.
  static const Color onCamera = Color(0xFFFFFFFF);

  /// Secondary text over the picture (70% white).
  static const Color onCameraMuted = Color(0xB3FFFFFF);

  /// Backing for pills and icon buttons that sit on the picture.
  static const Color overlay = Color(0x73000000);

  /// The selected mode tab, visible on black (about 12% white).
  static const Color selected = Color(0x1FFFFFFF);

  /// The recording colour.
  static const Color record = Color(0xFFFF3B30);

  static const double iconSize = 24;

  /// Smallest comfortable touch target (Material asks for 48dp).
  static const double minTarget = 48;

  static const double gutter = 16;

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: record,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: scheme.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
      ),
    );
  }
}
