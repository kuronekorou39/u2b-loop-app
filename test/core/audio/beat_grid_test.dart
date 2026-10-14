import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/bpm_key_detector.dart';

const _sr = BpmKeyDetector.analysisSampleRate;

/// [offsetMs] から始まる指定 BPM のクリック音（短いノイズバースト）
Int16List _click(double bpm, {double offsetMs = 0, int seconds = 60}) {
  final y = Int16List(_sr * seconds);
  final period = _sr * 60 / bpm;
  final rng = Random(0);
  for (var k = 0;; k++) {
    final i = (offsetMs / 1000 * _sr + k * period).round();
    if (i + 300 >= y.length) break;
    for (var j = 0; j < 300; j++) {
      y[i + j] = ((rng.nextDouble() * 2 - 1) * (1 - j / 300) * 20000).round();
    }
  }
  return y;
}

void main() {
  group('拍の格子の検出', () {
    for (final (bpm, offset) in [(128.0, 137.0), (97.0, 410.0), (174.0, 0.0)]) {
      test('$bpm BPM・最初の拍 ${offset}ms を当てる', () {
        final env = BpmKeyDetector.onsetEnvelope(_click(bpm, offsetMs: offset), _sr)!;
        // 自己相関の粗い BPM（0.1 刻み・ラグ整数）から始めても精密な値に寄る
        final grid = BpmKeyDetector.detectBeatGrid(env, (bpm * 10).round() / 10)!;
        expect(grid.bpm, closeTo(bpm, bpm * 0.0005), reason: '$grid');
        final period = 60000 / bpm;
        final got = grid.offsetMs % period;
        final want = offset % period;
        final diff = min((got - want).abs(), period - (got - want).abs());
        expect(diff, lessThan(12), reason: '$grid（期待 ${want}ms）');
      });
    }

    test('analyze は BPM と一緒に格子を返し、無音なら返さない', () {
      final result = BpmKeyDetector.analyze(_click(120, offsetMs: 250, seconds: 30), _sr);
      expect(result.bpm, closeTo(120, 2));
      expect(result.beatGrid, isNotNull);
      expect(BpmKeyDetector.analyze(Int16List(_sr * 10), _sr).beatGrid, isNull);
    });
  });

  group('BeatGrid', () {
    const grid = BeatGrid(bpm: 120, offsetMs: 100); // 1 拍 500ms、拍の頭は 100, 600, 1100…

    test('位相と次の拍まで', () {
      expect(grid.periodMs, 500);
      expect(grid.phaseAt(100), 0);
      expect(grid.phaseAt(350), closeTo(0.5, 1e-9));
      expect(grid.phaseAt(50), closeTo(0.9, 1e-9)); // 最初の拍より前も折り返す
      expect(grid.toNextBeatMs(100), 0);
      expect(grid.toNextBeatMs(350), closeTo(250, 1e-9));
    });
  });

  group('BeatMatcher', () {
    const out = BeatGrid(bpm: 120, offsetMs: 0); // 拍の頭 0, 500, 1000…
    const in_ = BeatGrid(bpm: 120, offsetMs: 200); // 拍の頭 200, 700, 1200…

    test('入る曲の開始位置を ±半拍でずらして拍の頭を揃える', () {
      // 出る曲は 60000ms（拍の頭）で交差開始。入る曲を 10000ms から始める予定 →
      // 10000 は入る曲では位相 0.6（次の拍 10200 まで 200ms）。
      // 出る曲の次の拍までは 500ms（= 0）なので、入る曲も拍の頭 10200 から始める
      final s = BeatMatcher.alignedStartMs(
          out: out, in_: in_, outPosMs: 60000, outRate: 1, inStartMs: 10000, inRate: 1);
      expect(s, closeTo(10200, 1e-6));
      // 出る曲が拍の 1/4 手前（次の拍まで 125ms）なら、入る曲も次の拍まで 125ms の位置から
      final s2 = BeatMatcher.alignedStartMs(
          out: out, in_: in_, outPosMs: 60375, outRate: 1, inStartMs: 10000, inRate: 1);
      expect(in_.toNextBeatMs(s2), closeTo(125, 1e-6));
      // ずらす量は半拍以内
      expect((s2 - 10000).abs(), lessThanOrEqualTo(250));
    });

    test('速度が違っても実時間で揃える', () {
      // 入る曲を 1.25 倍で鳴らす: 媒体 500ms の 1 拍は実時間 400ms。
      // 出る曲は次の拍まで 200ms → 入る曲は媒体 250ms 手前（位相 0.5）から
      final s = BeatMatcher.alignedStartMs(
          out: out, in_: in_, outPosMs: 60300, outRate: 1, inStartMs: 10000, inRate: 1.25);
      expect(in_.toNextBeatMs(s) / 1.25, closeTo(200, 1e-6));
    });

    test('位相誤差は入る曲が遅れていれば正、±半拍で折り返す', () {
      // 出る曲 60000（拍の頭）、入る曲 10150（次の拍 10200 まで 50ms）→ 入る曲が 50ms 遅れ
      expect(
          BeatMatcher.phaseErrorMs(
              out: out, in_: in_, outPosMs: 60000, outRate: 1, inPosMs: 10150, inRate: 1),
          closeTo(50, 1e-6));
      // 入る曲 10250（拍の頭を 50ms 過ぎた）→ −50ms（進んでいる）
      expect(
          BeatMatcher.phaseErrorMs(
              out: out, in_: in_, outPosMs: 60000, outRate: 1, inPosMs: 10250, inRate: 1),
          closeTo(-50, 1e-6));
      // ぴったりなら 0
      expect(
          BeatMatcher.phaseErrorMs(
              out: out, in_: in_, outPosMs: 60000, outRate: 1, inPosMs: 10200, inRate: 1),
          closeTo(0, 1e-6));
    });

    test('速度の変化は誤差に比例し、許容内なら 0、上限で止まる', () {
      expect(BeatMatcher.rateAdjust(3), 0);
      expect(BeatMatcher.rateAdjust(-3), 0);
      expect(BeatMatcher.rateAdjust(25), closeTo(0.01, 1e-9));
      expect(BeatMatcher.rateAdjust(-25), closeTo(-0.01, 1e-9));
      expect(BeatMatcher.rateAdjust(250), BeatMatcher.maxRateAdjust);
      expect(BeatMatcher.rateAdjust(-250), -BeatMatcher.maxRateAdjust);
    });
  });
}
