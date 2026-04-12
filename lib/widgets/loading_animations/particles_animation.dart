import 'dart:math';
import 'package:flutter/material.dart';
import 'loading_animation.dart';

/// 浮遊するパーティクルが近接時にラインで繋がるネットワーク風アニメーション。
class ParticlesAnimation extends LoadingAnimation {
  ParticlesAnimation({
    required super.elapsed,
    required super.size,
    required this.colors,
  });

  final List<Color> colors;

  static const _particleCount = 30;
  static const _connectionDistance = 120.0;

  @override
  void paint(Canvas canvas, Size size) {
    final particles = <Offset>[];

    for (var i = 0; i < _particleCount; i++) {
      final seed = i * 73 + 19;
      final sx = (0.15 + (seed % 11) * 0.04) * 0.5;
      final sy = (0.12 + (seed % 9) * 0.045) * 0.5;
      final px = seed * 1.1;
      final py = seed * 0.9;

      final x = (sin(elapsed * sx + px) * 0.5 + 0.5) * size.width;
      final y = (sin(elapsed * sy + py) * 0.5 + 0.5) * size.height;
      particles.add(Offset(x, y));
    }

    // パーティクル間の接続線
    for (var i = 0; i < _particleCount; i++) {
      for (var j = i + 1; j < _particleCount; j++) {
        final dist = (particles[i] - particles[j]).distance;
        if (dist < _connectionDistance) {
          final alpha = (1.0 - dist / _connectionDistance) * 0.15;
          final color = colors[i % colors.length];
          final paint = Paint()
            ..color = color.withValues(alpha: alpha)
            ..strokeWidth = 0.6;
          canvas.drawLine(particles[i], particles[j], paint);
        }
      }
    }

    // パーティクル本体
    for (var i = 0; i < _particleCount; i++) {
      final color = colors[i % colors.length];
      final breathe = 1.0 + 0.3 * sin(elapsed * 0.8 + i * 0.5);
      final radius = 1.8 * breathe;

      final paint = Paint()
        ..color = color.withValues(alpha: 0.4);
      canvas.drawCircle(particles[i], radius, paint);

      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(particles[i], radius * 2.5, glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant ParticlesAnimation oldDelegate) =>
      oldDelegate.elapsed != elapsed;
}
