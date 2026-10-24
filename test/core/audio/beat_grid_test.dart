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

    test('信頼度: クリック音は高く、拍の無いノイズは低い', () {
      final clicks = BpmKeyDetector.onsetEnvelope(_click(128, seconds: 30), _sr)!;
      final good = BpmKeyDetector.detectBeatGrid(clicks, 128)!;
      expect(good.confidence, greaterThan(0.5), reason: '$good');
      expect(good.reliable, isTrue);

      // 拍の無い音（ランダムな間隔の短い音）
      final rng = Random(1);
      final y = Int16List(_sr * 30);
      var i = 0;
      while (i + 300 < y.length) {
        for (var j = 0; j < 300; j++) {
          y[i + j] = ((rng.nextDouble() * 2 - 1) * (1 - j / 300) * 20000).round();
        }
        i += (_sr * (0.15 + rng.nextDouble() * 0.6)).round();
      }
      final noise = BpmKeyDetector.onsetEnvelope(y, _sr)!;
      final bad = BpmKeyDetector.detectBeatGrid(noise, 128)!;
      expect(bad.confidence, lessThan(BeatGrid.minConfidence), reason: '$bad');
      expect(bad.reliable, isFalse);
    });

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

    test('直前の拍の頭', () {
      expect(grid.floorBeatMs(600), closeTo(600, 1e-9));
      expect(grid.floorBeatMs(1099), closeTo(600, 1e-9));
      expect(grid.floorBeatMs(1100), closeTo(1100, 1e-9));
    });

    test('小節の格子: 基準点に最も近い拍を小節頭として 4 拍ごと', () {
      // 基準点なし → 最初の拍（100）が小節頭。小節は 2000ms
      final bars = grid.barGrid();
      expect(bars.periodMs, 2000);
      expect(bars.offsetMs, 100);
      // ドロップが 3610ms（拍の頭 3600 のすぐ後）→ 3600 を小節頭に。1600, 3600, 5600…
      final anchored = grid.barGrid(3610);
      expect(anchored.offsetMs, closeTo(1600, 1e-9));
      expect(anchored.floorBeatMs(5000), closeTo(3600, 1e-9));
      expect(anchored.confidence, 1);
    });

    test('小節頭: 解析の小節頭が確かならドロップより優先、不確かならドロップ', () {
      // 拍は 100, 600, 1100, 1600…。解析の 1 拍目は 600
      const sure = BeatGrid(
          bpm: 120, offsetMs: 100, downbeatMs: 600, downbeatConfidence: 0.8);
      expect(sure.barGrid(3610).offsetMs, closeTo(600, 1e-9));
      const unsure = BeatGrid(
          bpm: 120, offsetMs: 100, downbeatMs: 600, downbeatConfidence: 0.3);
      expect(unsure.barGrid(3610).offsetMs, closeTo(1600, 1e-9));
    });

    test('フレーズの格子: ドロップに最も近い小節頭から 8 小節ごと', () {
      // 拍 100, 600, …（500ms）。小節 2000ms、フレーズ 16000ms。
      // 解析の 1 拍目 600 → 小節頭は 600, 2600, 4600, …。ドロップ 20650 に最も近い小節頭は 20600
      const g = BeatGrid(
          bpm: 120, offsetMs: 100, downbeatMs: 600, downbeatConfidence: 1);
      final phrases = g.phraseGrid(20650);
      expect(phrases.periodMs, closeTo(16000, 1e-9));
      expect(phrases.offsetMs, closeTo(4600, 1e-9));
      expect(phrases.floorBeatMs(40000), closeTo(36600, 1e-9));
      // ドロップが無ければ小節頭の基準（600）から
      expect(g.phraseGrid().offsetMs, closeTo(600, 1e-9));
      // ドロップが小節の 2 拍目（21100）にあっても、フレーズの頭は小節頭に揃う
      expect(g.phraseGrid(21100).offsetMs, closeTo(4600, 1e-9));
    });

    test('拍の線: 範囲の拍と何拍目か（基準と同じ数え方）', () {
      const g = BeatGrid(
          bpm: 120, offsetMs: 100, downbeatMs: 600, downbeatConfidence: 1);
      final beats = g.beatsBetween(500, 2700).toList();
      expect([for (final b in beats) b.ms], [600, 1100, 1600, 2100, 2600]);
      expect([for (final b in beats) b.number], [1, 2, 3, 4, 1]);
      // 小節頭より前も数えられる（100 は 600 の 1 拍前 = 4 拍目）
      expect(g.beatsBetween(0, 200).single.number, 4);
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

    test('小節の格子で揃えると、入る曲の 1 拍目が出る曲の 1 拍目に重なる', () {
      // 出る曲の 1 拍目は 1500, 3500…（拍 0, 500, 1000, 1500 の 4 つ目）
      const outBars = BeatGrid(
          bpm: 120, offsetMs: 0, downbeatMs: 1500, downbeatConfidence: 1);
      // 入る曲の 1 拍目は 700, 2700…
      const inBars = BeatGrid(
          bpm: 120, offsetMs: 200, downbeatMs: 700, downbeatConfidence: 1);
      // 出る曲は 61500（1 拍目）で交差開始。入る曲は 10000 から始める予定
      final s = BeatMatcher.alignedStartMs(
          out: outBars.barGrid(),
          in_: inBars.barGrid(),
          outPosMs: 61500,
          outRate: 1,
          inStartMs: 10000,
          inRate: 1);
      // 入る曲も 1 拍目（700 + 2000n）から始まる。10000 に一番近いのは 10700
      expect(s, closeTo(10700, 1e-6));
      expect(inBars.beatsBetween(s - 1, s + 1).single.number, 1);
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

  group('shiftedBy（ジョグで合わせた分を格子に焼き込む）', () {
    // 出る曲: 拍 0,500… 1 拍目 1500。入る曲: 拍 200,700… 1 拍目 700
    const outBars =
        BeatGrid(bpm: 120, offsetMs: 0, downbeatMs: 1500, downbeatConfidence: 1);
    const in_ =
        BeatGrid(bpm: 120, offsetMs: 200, downbeatMs: 700, downbeatConfidence: 1);

    test('位相（offset）は 1 拍ぶんに収めて、小節頭（downbeat）はそのまま動く', () {
      final g = in_.shiftedBy(80);
      expect(g.offsetMs, closeTo(280, 1e-9));
      expect(g.downbeatMs, closeTo(780, 1e-9));
      // 1 拍（500ms）ぶん進めても位相は変わらない（折り返す）が、小節頭は 1 拍動く
      final one = in_.shiftedBy(500);
      expect(one.offsetMs, closeTo(200, 1e-9));
      expect(one.downbeatMs, closeTo(1200, 1e-9));
      // マイナスも 0〜1 拍に収まる
      expect(in_.shiftedBy(-80).offsetMs, closeTo(120, 1e-9));
    });

    test('焼き込むと、次の自動の拍合わせが手で合わせた開始位置をそのまま出す', () {
      const outPos = 61500.0; // 出る曲の 1 拍目で交差開始
      const inStart = 10000.0;
      final base = BeatMatcher.alignedStartMs(
          out: outBars.barGrid(),
          in_: in_.barGrid(),
          outPosMs: outPos,
          outRate: 1,
          inStartMs: inStart,
          inRate: 1);
      // 手で δ だけ入る曲を先へ動かして合わせた → その分を格子へ焼く
      for (final d in [60.0, -60.0, 300.0, -300.0]) {
        final shifted = in_.shiftedBy(d);
        final after = BeatMatcher.alignedStartMs(
            out: outBars.barGrid(),
            in_: shifted.barGrid(),
            outPosMs: outPos,
            outRate: 1,
            inStartMs: inStart,
            inRate: 1);
        expect(after, closeTo(base + d, 1e-6),
            reason: 'δ=$d を焼き込むと開始が δ 分ずれる');
      }
    });

    test('入る曲を前へ（+）動かすと遅れ（+）のずれが減る＝ジョグの向きと保存の向きが揃う', () {
      // 入る曲 10150（50ms 遅れ）。ジョグは音源を +50 進めてずれ 0 にする
      final late = BeatMatcher.phaseErrorMs(
          out: outBars, in_: in_, outPosMs: 60000, outRate: 1, inPosMs: 10150, inRate: 1);
      expect(late, closeTo(50, 1e-6));
      final fixed = BeatMatcher.phaseErrorMs(
          out: outBars, in_: in_, outPosMs: 60000, outRate: 1, inPosMs: 10150 + 50, inRate: 1);
      expect(fixed, closeTo(0, 1e-6));
      // そうやって +50 で合わせた分を shiftedBy(+50) で焼くと、次回も同じ開始に揃う（上のテスト）
    });
  });
}
