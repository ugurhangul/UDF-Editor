import 'package:flutter/material.dart';

/// UDFtör Material 3 theme configuration.
///
/// Adaptive colors for iOS/Android. Supports dark mode.
class AppTheme {
  AppTheme._();

  // -- Brand Colors --
  static const _primarySeed = Color(0xFF1565C0); // Deep blue
  static const _secondarySeed = Color(0xFF00897B); // Teal accent

  static final lightScheme = ColorScheme.fromSeed(
    seedColor: _primarySeed,
    secondary: _secondarySeed,
    brightness: Brightness.light,
  );

  static final darkScheme = ColorScheme.fromSeed(
    seedColor: _primarySeed,
    secondary: _secondarySeed,
    brightness: Brightness.dark,
  );

  static ThemeData light() => _buildTheme(lightScheme);
  static ThemeData dark() => _buildTheme(darkScheme);

  static ThemeData _buildTheme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Roboto',

      // -- AppBar --
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),

      // -- Cards --
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant, width: 0.5),
        ),
      ),

      // -- Bottom Navigation --
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),

      // -- FAB --
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      // -- Input --
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),

      // -- Snackbar --
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  // -- Document Display --

  /// Map UDF font sizes (in points) to Flutter logical pixels.
  /// UDF uses ~1pt = 1.33px at standard density.
  static double udfFontSizeToLogical(int udfSize) => udfSize * 1.33;
}
