import 'dart:math';
import 'package:flutter/material.dart';
import 'loading_animation.dart';

/// Windows スクリーンセイバー「ミスティファイ」風のラインアート。
/// 複数の頂点が独立に動き、それらを繋ぐ多角形の軌跡が残る。
class MystifyAnimation extends LoadingAnimation {
  MystifyAnimation({
    required super.elapsed,
    required super.size,
    required this.colors,
  });

  final List<Color> colors;

  static const _shapeCount = 2;
  static const _vertexCount = 4;
  static const _trailCount = 6;
  static const _trailFadeStep = 0.12;

  @override
  void paint(Canvas canvas, Size size) {
    for (var s = 0; s < _shapeCount; s++) {
      final color = colors[s % colors.length];

      for (var t = 0; t < _trailCount; t++) {
        final age = t * 0.12;
        final time = elapsed - age;
        if (time < 0) continue;

        final alpha = (1.0 - t * _trailFadeStep).clamp(0.05, 1.0);
        final paint = Paint()
          ..color = color.withValues(alpha: alpha * 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1.2 - t * 0.12).clamp(0.4, 1.2);

        final path = Path();
        for (var v = 0; v <= _vertexCount; v++) {
          final vi = v % _vertexCount;
          final pt = _vertexPosition(s, vi, time, size);
          if (v == 0) {
            path.moveTo(pt.dx, pt.dy);
          } else {
            path.lineTo(pt.dx, pt.dy);
          }
        }

        canvas.drawPath(path, paint);
      }
    }
  }

  Offset _vertexPosition(int shape, int vertex, double time, Size size) {
    final seed = shape * 100 + vertex * 17;
    final sx = (0.3 + (seed % 7) * 0.08) * 0.5;
    final sy = (0.25 + (seed % 5) * 0.09) * 0.5;
    final px = seed * 1.3;
    final py = seed * 0.7;

    final nx = (sin(time * sx + px) * 0.5 + 0.5);
    final ny = (sin(time * sy + py) * 0.5 + 0.5);

    return Offset(
      nx * size.width,
      ny * size.height,
    );
  }

  @override
  bool shouldRepaint(covariant MystifyAnimation oldDelegate) =>
      oldDelegate.elapsed != elapsed;
}
