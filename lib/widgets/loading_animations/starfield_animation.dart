import 'dart:math';
import 'package:flutter/material.dart';
import 'loading_animation.dart';

/// スターフィールド（星が奥から手前に流れる）アニメーション。
class StarfieldAnimation extends LoadingAnimation {
  StarfieldAnimation({
    required super.elapsed,
    required super.size,
    required this.colors,
  });

  final List<Color> colors;

  static const _starCount = 80;
  static const _speed = 0.4;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final maxRadius = size.width * 0.6;

    for (var i = 0; i < _starCount; i++) {
      // 各星に固有の角度と初期深度を seed から決定
      final seed = i * 127 + 31;
      final angle = (seed % 360) * pi / 180;
      final initialDepth = (seed % 1000) / 1000.0;

      // depth: 0(奥) → 1(手前) をループ
      final depth = (initialDepth + elapsed * _speed) % 1.0;

      // 奥は中心近く、手前は端に広がる（指数的に）
      final spread = depth * depth;
      final x = cx + cos(angle) * spread * maxRadius;
      final y = cy + sin(angle) * spread * maxRadius;

      // 画面外ならスキップ
      if (x < 0 || x > size.width || y < 0 || y > size.height) continue;

      final starSize = 0.5 + depth * 2.5;
      final alpha = (depth * 0.9 + 0.1).clamp(0.0, 1.0);
      final color = colors[i % colors.length];

      final paint = Paint()
        ..color = color.withValues(alpha: alpha * 0.8);

      canvas.drawCircle(Offset(x, y), starSize, paint);

      // 手前の星にはトレイルを描画
      if (depth > 0.5) {
        final trailLength = (depth - 0.5) * 2.0;
        final prevSpread = (depth - 0.02) * (depth - 0.02);
        final px = cx + cos(angle) * prevSpread * maxRadius;
        final py = cy + sin(angle) * prevSpread * maxRadius;

        final trailPaint = Paint()
          ..color = color.withValues(alpha: alpha * 0.3 * trailLength)
          ..strokeWidth = starSize * 0.6
          ..style = PaintingStyle.stroke;

        canvas.drawLine(Offset(px, py), Offset(x, y), trailPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant StarfieldAnimation oldDelegate) =>
      oldDelegate.elapsed != elapsed;
}
