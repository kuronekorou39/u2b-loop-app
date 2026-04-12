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

    for (var w = _waveCount - 1; w >= 0; w--) {
      final params = _waveParams[w];
      final freq = params[0];
      final amp = params[1] * maxAmplitude;
      final speed = params[2];
      final phase = params[3];

      final color = colors[w % colors.length];
      final paint = Paint()
        ..color = color.withValues(alpha: 0.15 + 0.2 * (1 - w / _waveCount))
        ..style = PaintingStyle.fill;

      final strokePaint = Paint()
        ..color = color.withValues(alpha: 0.5 + 0.3 * (1 - w / _waveCount))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      final path = Path();
      final strokePath = Path();
      const step = 2.0;

      for (var x = 0.0; x <= size.width; x += step) {
        final nx = x / size.width;
        // 複数の sin を重ねて有機的な動きを作る
        final y = centerY +
            amp *
                sin(nx * pi * 2 * freq + elapsed * speed + phase) *
                (0.7 + 0.3 * sin(elapsed * 0.4 + nx * pi + w));

        if (x == 0) {
          path.moveTo(x, y);
          strokePath.moveTo(x, y);
        } else {
          path.lineTo(x, y);
          strokePath.lineTo(x, y);
        }
      }

      // 塗りつぶし用: 下端まで閉じる
      final fillPath = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();

      canvas.drawPath(fillPath, paint);
      canvas.drawPath(strokePath, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveAnimation oldDelegate) =>
      oldDelegate.elapsed != elapsed;
}
