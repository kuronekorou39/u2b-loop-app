import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 帯域の波形の色（濃い = 低音、明るい = 中音、白に近い = 高音）。
/// ふつうの波形は緑、重ね表示は前の曲が赤・次の曲が青（曲の区別の色は保つ）
class BandPalette {
  const BandPalette(this.low, this.mid, this.high);

  final Color low;
  final Color mid;
  final Color high;

  static const green = BandPalette(
    Color(0xFF1E7D60),
    AppTheme.accentGreen,
    Color(0xFFD6F5EA),
  );
  static const red = BandPalette(
    Color(0xFF962D2D),
    AppTheme.pointAColor,
    Color(0xFFFFD7D7),
  );
  static const blue = BandPalette(
    Color(0xFF1446AA),
    AppTheme.pointBColor,
    Color(0xFFD7F0FF),
  );
}

/// 帯域の棒 1 本（上下対称）。低音を一番外に、中音・高音を内側に重ねる。
/// 中音・高音は低音より小さく出る（サンプルで見比べて決めた比: 中 0.62、高 0.28）
class BandBars {
  BandBars._();

  static const _midScale = 0.62;
  static const _highScale = 0.28;

  /// まだ鳴っていない側をどれだけ暗くするか
  static const _dimAmount = 0.55;

  static void paint(
    Canvas canvas, {
    required double centerX,
    required double width,
    required double midY,
    required double maxHalfHeight,
    required ({double low, double mid, double high}) bands,
    required BandPalette palette,
    required double opacity,
    bool dim = false,
  }) {
    // まだ鳴っていない側は色を暗くする（透かすと 3 色が混ざって濁るので、色そのものを沈める）
    void bar(double v, Color base) {
      final c = dim ? Color.lerp(base, Colors.black, _dimAmount)! : base;
      final h = (v * maxHalfHeight).clamp(0.5, maxHalfHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(centerX, midY), width: width, height: h * 2),
          Radius.circular(width / 2 < 1 ? width / 2 : 1),
        ),
        Paint()..color = c.withValues(alpha: opacity),
      );
    }

    bar(bands.low, palette.low);
    bar(bands.mid * _midScale, palette.mid);
    bar(bands.high * _highScale, palette.high);
  }
}
