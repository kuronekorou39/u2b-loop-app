import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/tempo_resolver.dart';

const _sr = 11025;

/// [bpm] の 4 拍のパターンを鳴らす: 1 拍目は低音、2 拍目は中音、3 拍目は低音 + 中音、
/// 4 拍目は高音。拍ごとに音色が違うので、音の並びは 4 拍ごとに戻る
Int16List _pattern(double bpm, {int seconds = 60}) {
  final n = _sr * seconds;
  final out = Float64List(n);
  final beat = 60 / bpm * _sr;
  const freqs = [
    [80.0],
    [700.0],
    [80.0, 1500.0],
    [3500.0],
  ];
  final hit = (0.06 * _sr).round();
  for (var k = 0;; k++) {
    final at = (k * beat).round();
    if (at + hit >= n) break;
    for (final f in freqs[k % 4]) {
      for (var i = 0; i < hit; i++) {
        final env = exp(-i / (0.015 * _sr));
        out[at + i] += 0.5 * env * sin(2 * pi * f * i / _sr);
      }
    }
  }
  return Int16List.fromList([for (final v in out) (v.clamp(-1.0, 1.0) * 32000).round()]);
}

Int16List _noise({int seconds = 40}) {
  final r = Random(7);
  return Int16List.fromList(
      List.generate(_sr * seconds, (_) => ((r.nextDouble() - 0.5) * 8000).round()));
}

/// 実際の曲で測った「小節の戻り」の表で判断を確かめる（[c] に一番近い行の値）
double Function(double) _table(Map<double, double> t) => (c) {
      var best = t.keys.first;
      for (final k in t.keys) {
        if ((k - c).abs() < (best - c).abs()) best = k;
      }
      return t[best]!;
    };

void main() {
  group('decide（2026-11-21 に実際の曲で測った値）', () {
    double decide(double bpm, Map<double, double> bar, {double pulse = 0.3}) =>
        TempoResolver.decide(bpm, bar: _table(bar), pulse: (_) => pulse);

    test('2:3 に取り違えた曲を直す（Super Sonic Racing: 110 → 165）', () {
      expect(
          decide(110.02, {73.3: 0.292, 82.5: 0.397, 110: 0.330, 146.7: 0.272, 165: 0.368}),
          closeTo(165, 0.1),
          reason: '82.5 が一番戻るが、同じくらい戻る倍の 165 のほうが拍として聞きやすい');
      expect(
          decide(109.96, {73.3: 0.231, 82.5: 0.283, 110: 0.284, 146.7: 0.248, 165: 0.338}),
          closeTo(165, 0.1));
    });

    test('半分に取り違えた曲は、半拍にも刻みがあれば倍にする（Diamond in the Sky: 75 → 150）', () {
      expect(decide(75.01, {75: 0.406, 100: 0.335, 112.5: -0.053, 150: 0.401}, pulse: 0.269),
          closeTo(150, 0.1));
    });

    test('本当に遅い曲は半拍に刻みが無いので倍にしない（Losin\' Streak: 67）', () {
      expect(decide(67, {67: 0.183, 89: 0.150, 100: 0.092, 134: 0.190}, pulse: -0.04), 67);
    });

    test('合っている曲は動かさない', () {
      // Living in the City
      expect(decide(148.02, {98.7: 0.340, 111: -0.041, 148: 0.361, 197.4: 0.303}), 148.02);
      // Ringleader: 2:3 系がわずかに上でも動かさない
      expect(decide(145, {96.7: 0.197, 108.8: -0.037, 145: 0.209, 193.3: 0.212}), 145);
    });

    test('音の並びが戻らない曲は判断しない', () {
      expect(decide(115, {76.7: 0.01, 86: 0.05, 115: 0.02, 153: 0.0, 172: 0.09}), 115);
    });
  });

  double resolve(Int16List pcm, double bpm) {
    final flux = BandFlux.of(pcm, _sr)!;
    return TempoResolver.resolve(flux, 0, flux.frames, bpm);
  }

  test('本当のテンポのままなら変えない', () {
    expect(resolve(_pattern(150), 150), 150);
    expect(resolve(_pattern(121), 121), 121);
  });

  test('半分のテンポと出た音は、毎拍に刻みがあるので倍に直す', () {
    expect(resolve(_pattern(150), 75), closeTo(150, 0.1));
  });

  test('音の並びが戻らない音（雑音）は判断せず変えない', () {
    expect(resolve(_noise(), 110), 110);
    expect(resolve(_noise(), 75), 75);
  });

  test('短すぎる音は測れない', () {
    expect(BandFlux.of(Int16List(1000), _sr), isNull);
  });

  test('同じ音の並びは、その周期で自己相似が高く、ずらすと低い', () {
    final flux = BandFlux.of(_pattern(120), _sr)!;
    final bar = (4 * 60 / 120 * flux.fps).round();
    final off = (3 * 60 / 120 * flux.fps).round();
    expect(flux.selfSimilarity(0, flux.frames, bar),
        greaterThan(flux.selfSimilarity(0, flux.frames, off) + 0.05));
  });
}
