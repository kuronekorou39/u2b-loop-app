import 'package:flutter/material.dart';

// === Design System Constants ===

class AppSpacing {
  static const xs = 4.0;
  static const sm = 6.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;
}

class AppIconSizes {
  static const xs = 14.0;
  static const sm = 18.0;
  static const md = 20.0;
  static const lg = 24.0;
  static const xl = 28.0;
  static const xxl = 48.0;
}

// === Theme ===

class AppTheme {
  static const pointAColor = Color(0xFFFF6B6B);
  static const pointBColor = Color(0xFF4FC3F7);
  static const accentGreen = Color(0xFF4ECCA3);
  static const accentRed = Color(0xFFE94560);

  static const _fontFamily = 'Roboto';

  static TextTheme _buildTextTheme(Brightness brightness) {
    final color =
        brightness == Brightness.dark ? Colors.white : const Color(0xFF1A1A2E);
    final subColor =
        brightness == Brightness.dark ? Colors.grey : Colors.grey.shade600;

    return TextTheme(
      // AppBar タイトル、大見出し
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        fontFamily: _fontFamily,
        color: color,
      ),
      // セクション見出し、ダイアログタイトル
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.bold,
        fontFamily: _fontFamily,
        color: color,
      ),
      // サブタイトル、ボタンラベル
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        fontFamily: _fontFamily,
        color: color,
      ),
      // 本文
      bodyLarge: TextStyle(
        fontSize: 14,
        fontFamily: _fontFamily,
        color: color,
      ),
      // リスト項目テキスト
      bodyMedium: TextStyle(
        fontSize: 13,
        fontFamily: _fontFamily,
        color: color,
      ),
      // 補助テキスト、ヒント
      bodySmall: TextStyle(
        fontSize: 12,
        fontFamily: _fontFamily,
        color: subColor,
      ),
      // キャプション、バッジ
      labelSmall: TextStyle(
        fontSize: 11,
        fontFamily: _fontFamily,
        color: subColor,
      ),
      // チップ、タグ
      labelMedium: TextStyle(
        fontSize: 12,
        fontFamily: _fontFamily,
        color: color,
      ),
    );
  }

  static ThemeData get dark {
    const bg = Color(0xFF1A1A2E);
    const bgSecondary = Color(0xFF16213E);
    const accent = Color(0xFF4ECCA3);
    const accentRed = Color(0xFFE94560);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      fontFamily: _fontFamily,
      textTheme: _buildTextTheme(Brightness.dark),
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
      dividerTheme: DividerThemeData(
        color: Colors.grey.shade800,
        space: 1,
        thickness: 1,
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
      fontFamily: _fontFamily,
      textTheme: _buildTextTheme(Brightness.light),
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
      dividerTheme: DividerThemeData(
        color: Colors.grey.shade300,
        space: 1,
        thickness: 1,
      ),
    );
  }
}
