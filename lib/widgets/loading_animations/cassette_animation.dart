import 'dart:math';
import 'package:flutter/material.dart';
import 'loading_animation.dart';

class CassetteAnimation extends LoadingAnimation {
  CassetteAnimation({required super.elapsed});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final scale = min(size.width, size.height) / 300;
    final t = elapsed;

    // カセット本体
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: 240 * scale, height: 150 * scale),
      Radius.circular(12 * scale),
    );
    canvas.drawRRect(
      bodyRect,
      Paint()
        ..color = const Color(0xFF2A2A3E)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      bodyRect,
      Paint()
        ..color = const Color(0xFF4ECCA3).withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * scale,
    );

    // ラベル窓
    final windowRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy - 10 * scale), width: 160 * scale, height: 60 * scale),
      Radius.circular(6 * scale),
    );
    canvas.drawRRect(
      windowRect,
      Paint()
        ..color = const Color(0xFF1A1A2E)
        ..style = PaintingStyle.fill,
    );

    // リール（左右の回転する円）
    final reelRadius = 20.0 * scale;
    final reelY = cy - 10 * scale;
    final leftReelX = cx - 45 * scale;
    final rightReelX = cx + 45 * scale;
    final rotation = t * 3; // 回転速度

    _drawReel(canvas, leftReelX, reelY, reelRadius, rotation, scale);
    _drawReel(canvas, rightReelX, reelY, reelRadius, -rotation * 0.7, scale);

    // テープライン（リール間）
    canvas.drawLine(
      Offset(leftReelX + reelRadius, reelY),
      Offset(rightReelX - reelRadius, reelY),
      Paint()
        ..color = const Color(0xFF4ECCA3).withValues(alpha: 0.5)
        ..strokeWidth = 1.5 * scale,
    );

    // 下部ヘッド窓
    final headRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + 50 * scale), width: 80 * scale, height: 16 * scale),
      Radius.circular(4 * scale),
    );
    canvas.drawRRect(
      headRect,
      Paint()
        ..color = const Color(0xFF1A1A2E)
        ..style = PaintingStyle.fill,
    );

    // ネジ穴（四隅）
    for (final offset in [
      Offset(cx - 100 * scale, cy - 55 * scale),
      Offset(cx + 100 * scale, cy - 55 * scale),
      Offset(cx - 100 * scale, cy + 55 * scale),
      Offset(cx + 100 * scale, cy + 55 * scale),
    ]) {
      canvas.drawCircle(
        offset,
        3 * scale,
        Paint()..color = const Color(0xFF4ECCA3).withValues(alpha: 0.2),
      );
    }

    // ラベルテキスト風のライン
    for (var i = 0; i < 3; i++) {
      final lineY = cy - 35 * scale + i * 8 * scale;
      final lineWidth = (70 - i * 15) * scale;
      canvas.drawLine(
        Offset(cx - lineWidth / 2, lineY),
        Offset(cx + lineWidth / 2, lineY),
        Paint()
          ..color = const Color(0xFF4ECCA3).withValues(alpha: 0.15)
          ..strokeWidth = 2 * scale
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawReel(Canvas canvas, double cx, double cy, double radius,
      double rotation, double scale) {
    // 外円
    canvas.drawCircle(
      Offset(cx, cy),
      radius,
      Paint()
        ..color = const Color(0xFF4ECCA3).withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * scale,
    );

    // 内円
    canvas.drawCircle(
      Offset(cx, cy),
      6 * scale,
      Paint()
        ..color = const Color(0xFF4ECCA3).withValues(alpha: 0.4)
        ..style = PaintingStyle.fill,
    );

    // スポーク（回転）
    for (var i = 0; i < 3; i++) {
      final angle = rotation + i * pi * 2 / 3;
      canvas.drawLine(
        Offset(cx + cos(angle) * 6 * scale, cy + sin(angle) * 6 * scale),
        Offset(cx + cos(angle) * radius * 0.85, cy + sin(angle) * radius * 0.85),
        Paint()
          ..color = const Color(0xFF4ECCA3).withValues(alpha: 0.3)
          ..strokeWidth = 1.5 * scale
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CassetteAnimation old) => true;
}
