import 'package:flutter/material.dart';

import '../../core/audio/beat_grid.dart';

/// 波形に重ねる拍の線（拍合わせが合っているかを目で確かめる用）。
/// 1 拍目（小節頭）は濃く、ほかの拍は薄く。拍の間が狭すぎるときは小節頭だけ、
/// それも狭ければ描かない
class BeatLines {
  BeatLines._();

  /// 線どうしがこれより詰まるなら描かない（px）
  static const _minGapPx = 5.0;

  /// 拍の間がこれ以上あれば何拍目かの数字も出す（px）
  static const _numberGapPx = 22.0;

  /// [grid] の拍を [startMs]〜[endMs]（曲の時刻）の範囲で描く。
  /// [toX] は曲の時刻 → x 座標。[anchorMs] は小節頭の代わりの基準（ドロップなど）。
  /// [numbers] なら拍の間が広いとき 1〜4 を出す（上端、[numbersAtBottom] なら下端）
  static void paint(
    Canvas canvas, {
    required BeatGrid grid,
    required double? anchorMs,
    required double startMs,
    required double endMs,
    required double Function(double ms) toX,
    required double top,
    required double bottom,
    required Color color,
    bool numbers = false,
    bool numbersAtBottom = false,
  }) {
    final beatPx = (toX(startMs + grid.periodMs) - toX(startMs)).abs();
    final barPx = beatPx * BeatGrid.beatsPerBar;
    if (barPx < _minGapPx) return;
    final allBeats = beatPx >= _minGapPx;
    final showNumbers = numbers && beatPx >= _numberGapPx;
    final barPaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1.2;
    final beatPaint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (final b
        in grid.beatsBetween(startMs, endMs, anchorMs: anchorMs)) {
      final downbeat = b.number == 1;
      if (!downbeat && !allBeats) continue;
      final x = toX(b.ms);
      canvas.drawLine(Offset(x, top), Offset(x, bottom),
          downbeat ? barPaint : beatPaint);
      if (showNumbers) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${b.number}',
            style: TextStyle(
              fontSize: 9,
              height: 1,
              fontWeight: downbeat ? FontWeight.bold : FontWeight.normal,
              color: color.withValues(alpha: downbeat ? 0.9 : 0.5),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas,
            Offset(x + 2, numbersAtBottom ? bottom - tp.height - 1 : top + 1));
      }
    }
  }
}
