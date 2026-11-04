import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/widgets/loop/beat_lines.dart';

/// 引いた線の x を数えるだけのキャンバス
class _LineCanvas implements Canvas {
  final xs = <double>[];
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => xs.add(p1.dx);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  // 120 BPM（1 拍 500ms、1 小節 2 秒）、小節頭 0
  const grid = BeatGrid(bpm: 120, offsetMs: 0, confidence: 0.9, downbeatMs: 0, downbeatConfidence: 0.9);

  List<double> paint({required double pxPerSec, bool thinOut = false}) {
    final c = _LineCanvas();
    BeatLines.paint(c,
        grid: grid,
        anchorMs: null,
        startMs: 0,
        endMs: 64000,
        toX: (ms) => ms / 1000 * pxPerSec,
        top: 0,
        bottom: 10,
        color: Colors.white,
        strong: true,
        thinOut: thinOut);
    return c.xs;
  }

  test('拡大できる波形: 小節頭でも詰まるなら線を出さない', () {
    expect(paint(pxPerSec: 2), isEmpty);
  });

  test('拡大できない波形: 詰まれば 4 小節（16 拍）ごと、もっと詰まれば 8 小節ごと', () {
    // 1 小節 = 2 秒 = 4px（< 8px）→ 4 小節ごと = 16px
    final four = paint(pxPerSec: 2, thinOut: true);
    expect(four.length, 64 ~/ 8 + 1);
    expect(four[1] - four[0], closeTo(16, 1e-6));
    // 1 小節 = 1.6px → 4 小節でも 6.4px → 8 小節ごと
    final eight = paint(pxPerSec: 0.8, thinOut: true);
    expect(eight[1] - eight[0], closeTo(12.8, 1e-6));
  });

  test('間が十分あれば拍ごと（間引きは関係ない）', () {
    expect(paint(pxPerSec: 40, thinOut: true).length, paint(pxPerSec: 40).length);
  });
}
