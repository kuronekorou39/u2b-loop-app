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

  /// 間引くときの小節の数（4 小節 = 16 拍、8 小節 = 32 拍 = 1 フレーズ）
  static const _thinBars = [4, 8];

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
    bool strong = false,
    bool thinOut = false,
  }) {
    final beatPx = (toX(startMs + grid.periodMs) - toX(startMs)).abs();
    final barPx = beatPx * BeatGrid.beatsPerBar;
    // 濃い版は線を太くする分、詰まって潰れないよう間を広めに取る
    final minGap = strong ? _minGapPx * 1.6 : _minGapPx;
    // 間引き（拡大できない波形）: 小節頭でも詰まるなら 4 小節（16 拍）、それでも詰まるなら
    // 8 小節（32 拍 = 1 フレーズ）ごとの小節頭だけ
    var everyBars = 1;
    if (barPx < minGap) {
      if (!thinOut) return;
      everyBars = [for (final n in _thinBars) if (barPx * n >= minGap) n].firstOrNull ?? 0;
      if (everyBars == 0) return;
    }
    final barMs = grid.periodMs * BeatGrid.beatsPerBar;
    final barAnchor = grid.barAnchorMs(anchorMs);
    final allBeats = beatPx >= minGap;
    final showNumbers = numbers && beatPx >= _numberGapPx;
    // 濃い版（単体再生の波形）: v1.108 で「細くて見えない」と言われたので小節頭は太く濃く
    final barPaint = Paint()
      ..color = color.withValues(alpha: strong ? 0.8 : 0.55)
      ..strokeWidth = strong ? 2.0 : 1.2;
    final beatPaint = Paint()
      ..color = color.withValues(alpha: strong ? 0.35 : 0.18)
      ..strokeWidth = 1;
    for (final b
        in grid.beatsBetween(startMs, endMs, anchorMs: anchorMs)) {
      final downbeat = b.number == 1;
      if (!downbeat && !allBeats) continue;
      if (everyBars > 1 && ((b.ms - barAnchor) / barMs).round() % everyBars != 0) continue;
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
