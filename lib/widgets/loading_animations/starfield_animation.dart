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
  static const _speed = 0.2;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final maxRadius = size.width * 0.6;

    for (var i = 0; i < _starCount; i++) {
      final seed = i * 127 + 31;
      final angle = (seed % 360) * pi / 180;
      final initialDepth = (seed % 1000) / 1000.0;

      final depth = (initialDepth + elapsed * _speed) % 1.0;

      final spread = depth * depth;
      final x = cx + cos(angle) * spread * maxRadius;
      final y = cy + sin(angle) * spread * maxRadius;

      if (x < 0 || x > size.width || y < 0 || y > size.height) continue;

      final starSize = 0.5 + depth * 2.0;
      final alpha = (depth * 0.5 + 0.05).clamp(0.0, 0.55);
      final color = colors[i % colors.length];

      final paint = Paint()
        ..color = color.withValues(alpha: alpha);

      canvas.drawCircle(Offset(x, y), starSize, paint);

      if (depth > 0.5) {
        final trailLength = (depth - 0.5) * 2.0;
        final prevSpread = (depth - 0.02) * (depth - 0.02);
        final px = cx + cos(angle) * prevSpread * maxRadius;
        final py = cy + sin(angle) * prevSpread * maxRadius;

        final trailPaint = Paint()
          ..color = color.withValues(alpha: alpha * 0.2 * trailLength)
          ..strokeWidth = starSize * 0.5
          ..style = PaintingStyle.stroke;

        canvas.drawLine(Offset(px, py), Offset(x, y), trailPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant StarfieldAnimation oldDelegate) =>
      oldDelegate.elapsed != elapsed;
}
