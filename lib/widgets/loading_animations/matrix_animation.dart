import 'dart:math';
import 'package:flutter/material.dart';
import 'loading_animation.dart';

class MatrixAnimation extends LoadingAnimation {
  MatrixAnimation({required super.elapsed});

  static final _random = Random();
  static final _chars = 'アイウエオカキクケコサシスセソタチツテト'
      'ナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン'
      '0123456789ABCDEF<>{}[]|/\\';

  // 列ごとの固定シード（フレーム間で一貫性を保つ）
  static final _columnSeeds = List.generate(60, (_) => _random.nextInt(10000));

  @override
  void paint(Canvas canvas, Size size) {
    final t = elapsed;
    final colWidth = 14.0;
    final cols = (size.width / colWidth).ceil();
    final rowHeight = 16.0;
    final rows = (size.height / rowHeight).ceil();

    for (var col = 0; col < cols && col < _columnSeeds.length; col++) {
      final seed = _columnSeeds[col];
      final speed = 2.0 + (seed % 30) / 10.0; // 2.0〜5.0
      final headRow = ((t * speed + seed) % (rows + 15)).toInt();

      for (var row = 0; row < rows; row++) {
        final dist = headRow - row;
        if (dist < 0 || dist > 12) continue;

        final alpha = (1.0 - dist / 12.0).clamp(0.0, 1.0);
        final charIndex = (seed + row * 7 + (t * 3).toInt()) % _chars.length;
        final char = _chars[charIndex];

        final isHead = dist == 0;
        final color = isHead
            ? Color.fromRGBO(180, 255, 180, alpha)
            : Color.fromRGBO(0, 200, 80, alpha * 0.7);

        final tp = TextPainter(
          text: TextSpan(
            text: char,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontFamily: 'monospace',
              fontWeight: isHead ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(col * colWidth, row * rowHeight));
      }
    }
  }

  @override
  bool shouldRepaint(covariant MatrixAnimation old) => true;
}
