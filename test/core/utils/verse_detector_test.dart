import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/verse_detector.dart';

/// [quietStartMs, quietEndMs] の区間だけ振幅が小さい波形を作る
List<double> _waveformWithQuietGap({
  required int durationMs,
  required int samples,
  required int quietStartMs,
  required int quietEndMs,
}) {
  final msPerSample = durationMs / samples;
  return List.generate(samples, (i) {
    final ms = i * msPerSample;
    return (ms >= quietStartMs && ms <= quietEndMs) ? 0.02 : 0.8;
  });
}

void main() {
  group('短い曲は切らない', () {
    test('50秒未満は null（全部流す）', () {
      expect(VerseDetector.findCutPoint(durationMs: 30000), isNull);
      expect(VerseDetector.findCutPoint(durationMs: 49999), isNull);
    });

    test('3分以下は null（曲全体が検索範囲に収まる）', () {
      expect(VerseDetector.findCutPoint(durationMs: 100000), isNull);
      expect(VerseDetector.findCutPoint(durationMs: 180000), isNull);
    });
  });

  group('波形が無いとき', () {
    test('フォールバックの1分40秒を返す', () {
      expect(VerseDetector.findCutPoint(durationMs: 300000), 100000);
    });

    test('サンプル数が少なすぎてもフォールバック', () {
      expect(
        VerseDetector.findCutPoint(
            durationMs: 300000, waveform: List.filled(50, 0.5)),
        100000,
      );
    });
  });

  group('波形があるとき', () {
    test('50秒〜3分の静かな部分を切断点にする', () {
      final waveform = _waveformWithQuietGap(
        durationMs: 300000,
        samples: 4000,
        quietStartMs: 70000,
        quietEndMs: 75000,
      );
      final cut =
          VerseDetector.findCutPoint(waveform: waveform, durationMs: 300000);
      expect(cut, isNotNull);
      expect(cut, greaterThanOrEqualTo(65000));
      expect(cut, lessThanOrEqualTo(80000));
    });

    test('切断点は必ず検索範囲（50秒〜3分）に収まる', () {
      final waveform = _waveformWithQuietGap(
        durationMs: 400000,
        samples: 4000,
        quietStartMs: 10000, // 検索範囲外の静かな部分に引っ張られないこと
        quietEndMs: 20000,
      );
      final cut =
          VerseDetector.findCutPoint(waveform: waveform, durationMs: 400000);
      expect(cut, isNotNull);
      expect(cut, greaterThanOrEqualTo(50000));
      expect(cut, lessThanOrEqualTo(180000));
    });

    test('2分台の静かな部分も切断点に選べる', () {
      final waveform = _waveformWithQuietGap(
        durationMs: 300000,
        samples: 4000,
        quietStartMs: 150000,
        quietEndMs: 155000,
      );
      final cut =
          VerseDetector.findCutPoint(waveform: waveform, durationMs: 300000);
      expect(cut, greaterThanOrEqualTo(145000));
      expect(cut, lessThanOrEqualTo(160000));
    });

    test('平坦な波形でも null にはならない', () {
      final cut = VerseDetector.findCutPoint(
          waveform: List.filled(4000, 0.5), durationMs: 300000);
      expect(cut, isNotNull);
    });
  });
}
