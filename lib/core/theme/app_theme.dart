import 'package:flutter/material.dart';

class AppTheme {
  static const pointAColor = Color(0xFFFF6B6B);
  static const pointBColor = Color(0xFF4ECCA3);

  static ThemeData get dark {
    const bg = Color(0xFF1A1A2E);
    const bgSecondary = Color(0xFF16213E);
    const accent = Color(0xFF4ECCA3);
    const accentRed = Color(0xFFE94560);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        surface: bg,
        primary: accent,
        secondary: accentRed,
        surfaceContainerHighest: bgSecondary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgSecondary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: bgSecondary,
        elevation: 0,
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: Colors.white),
      ),
    );
  }

  static ThemeData get light {
    const bg = Color(0xFFF5F5F5);
    const bgSecondary = Color(0xFFFFFFFF);
    const accent = Color(0xFF00A86B);
    const accentRed = Color(0xFFDC3055);

    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.light(
        surface: bg,
        primary: accent,
        secondary: accentRed,
        surfaceContainerHighest: bgSecondary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgSecondary,
        foregroundColor: Color(0xFF1A1A2E),
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: bgSecondary,
        elevation: 1,
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}
