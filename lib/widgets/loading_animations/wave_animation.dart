import 'dart:math';
import 'package:flutter/material.dart';
import 'loading_animation.dart';

/// 複数の正弦波を重ね合わせた波形アニメーション。
/// 音楽アプリらしい、有機的に動く波形を描画する。
class WaveAnimation extends LoadingAnimation {
  WaveAnimation({
    required super.elapsed,
    required super.size,
    required this.colors,
  });

  final List<Color> colors;

  static const _waveCount = 4;
  // 各波のパラメータ: [周波数倍率, 振幅倍率, 速度倍率, 位相オフセット]
  static const _waveParams = [
    [1.0, 1.0, 1.0, 0.0],
    [1.8, 0.6, 1.3, 0.8],
    [2.5, 0.35, 0.7, 1.6],
    [3.2, 0.2, 1.6, 2.4],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height * 0.5;
    final maxAmplitude = size.height * 0.18;
    final width = size.width;
    const step = 4.0;

    for (var w = _waveCount - 1; w >= 0; w--) {
      final params = _waveParams[w];
      final freq = params[0];
      final amp = params[1] * maxAmplitude;
      final speed = params[2];
      final phase = params[3];
      final modulation = 0.7 + 0.3 * sin(elapsed * 0.4 + w);

      final color = colors[w % colors.length];
      final fillPaint = Paint()
        ..color = color.withValues(alpha: 0.15 + 0.2 * (1 - w / _waveCount))
        ..style = PaintingStyle.fill;

      final strokePaint = Paint()
        ..color = color.withValues(alpha: 0.5 + 0.3 * (1 - w / _waveCount))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      final path = Path();
      final freqFactor = pi * 2 * freq;
      final timeOffset = elapsed * speed + phase;

      for (var x = 0.0; x <= width; x += step) {
        final nx = x / width;
        final y = centerY +
            amp * sin(nx * freqFactor + timeOffset) * modulation;

        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      // ストローク描画（パスを閉じる前）
      canvas.drawPath(path, strokePaint);

      // 塗りつぶし用: 下端まで閉じる
      path
        ..lineTo(width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(path, fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveAnimation oldDelegate) =>
      oldDelegate.elapsed != elapsed;
}
