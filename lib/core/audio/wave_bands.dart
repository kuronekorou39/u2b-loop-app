import 'dart:math';
import 'dart:typed_data';

import 'fft.dart';

/// 波形を音の高さで分けた 3 本（低音・中音・高音の大きさ、それぞれ 0〜1）。
///
/// 波形を色の濃淡で描くのに使う（濃い = 低音〔キック・ベース〕、明るい = 中音〔声・ギター〕、
/// 白に近い = 高音〔ハイハット〕。DJ ソフトの rekordbox と同じ考え方）。
/// 解析用の PCM（11025Hz モノラル）から [stepMs] ごとに求める。高音は物理的に小さいので、
/// 帯域ごとに曲の中の上位 1% の大きさで割って揃える（2026-11 のサンプルで見比べて決めた）
class WaveBands {
  WaveBands({required this.stepMs, required this.low, required this.mid, required this.high});

  /// 1 点の長さ（ミリ秒）
  final int stepMs;

  /// 0〜255（8bit）
  final Uint8List low;
  final Uint8List mid;
  final Uint8List high;

  int get length => low.length;

  /// 求めた範囲の長さ（ミリ秒）。PCM が打ち切られた長い曲はここまで
  int get durationMs => length * stepMs;

  static const defaultStepMs = 50;

  /// 帯域の境目（Hz）
  static const _lowMax = 200.0;
  static const _midMax = 2000.0;

  static const _fftSize = 1024;

  /// [startMs]〜[endMs] の各帯域の最大（0〜1）。範囲が求めた部分の外なら null
  ({double low, double mid, double high})? maxIn(double startMs, double endMs) {
    final i0 = (startMs / stepMs).floor();
    if (i0 < 0 || i0 >= length) return null;
    final i1 = max(i0 + 1, min(length, (endMs / stepMs).ceil()));
    var l = 0, m = 0, h = 0;
    for (var i = i0; i < i1; i++) {
      if (low[i] > l) l = low[i];
      if (mid[i] > m) m = mid[i];
      if (high[i] > h) h = high[i];
    }
    return (low: l / 255, mid: m / 255, high: h / 255);
  }

  /// PCM から求める（重いので isolate で呼ぶこと）。短すぎれば null
  static WaveBands? fromPcm(Int16List pcm, int sampleRate, {int stepMs = defaultStepMs}) {
    final hop = max(1, (sampleRate * stepMs / 1000).round());
    if (pcm.length < _fftSize) return null;
    final frames = 1 + (pcm.length - _fftSize) ~/ hop;
    final fft = Fft(_fftSize);
    final window = Float64List.fromList(
        List.generate(_fftSize, (i) => 0.5 - 0.5 * cos(2 * pi * i / (_fftSize - 1))));
    final re = Float64List(_fftSize), im = Float64List(_fftSize);
    final nb = _fftSize ~/ 2 + 1;
    final band = Int8List(nb);
    for (var k = 0; k < nb; k++) {
      final f = k * sampleRate / _fftSize;
      band[k] = f < 20 ? -1 : (f < _lowMax ? 0 : (f < _midMax ? 1 : 2));
    }
    final out = [Float64List(frames), Float64List(frames), Float64List(frames)];
    for (var fr = 0; fr < frames; fr++) {
      final base = fr * hop;
      for (var i = 0; i < _fftSize; i++) {
        re[i] = pcm[base + i] / 32768.0 * window[i];
        im[i] = 0;
      }
      fft.transform(re, im);
      var l = 0.0, m = 0.0, h = 0.0;
      for (var k = 0; k < nb; k++) {
        final p = re[k] * re[k] + im[k] * im[k];
        switch (band[k]) {
          case 0:
            l += p;
          case 1:
            m += p;
          case 2:
            h += p;
        }
      }
      out[0][fr] = sqrt(l);
      out[1][fr] = sqrt(m);
      out[2][fr] = sqrt(h);
    }
    Uint8List quantize(Float64List v) {
      final sorted = Float64List.fromList(v)..sort();
      final ref = sorted[min(sorted.length - 1, (sorted.length * 0.99).floor())];
      final q = Uint8List(v.length);
      if (ref <= 0) return q;
      for (var i = 0; i < v.length; i++) {
        q[i] = (min(1.0, v[i] / ref) * 255).round();
      }
      return q;
    }

    return WaveBands(
      stepMs: stepMs,
      low: quantize(out[0]),
      mid: quantize(out[1]),
      high: quantize(out[2]),
    );
  }

  /// 保存の形: [stepMs の下位, 上位] + low + mid + high
  Uint8List encode() {
    final b = Uint8List(2 + length * 3);
    b[0] = stepMs & 0xff;
    b[1] = (stepMs >> 8) & 0xff;
    b.setAll(2, low);
    b.setAll(2 + length, mid);
    b.setAll(2 + length * 2, high);
    return b;
  }

  static WaveBands? decode(Uint8List b) {
    if (b.length < 5 || (b.length - 2) % 3 != 0) return null;
    final n = (b.length - 2) ~/ 3;
    final step = b[0] | (b[1] << 8);
    if (step <= 0) return null;
    return WaveBands(
      stepMs: step,
      low: Uint8List.sublistView(b, 2, 2 + n),
      mid: Uint8List.sublistView(b, 2 + n, 2 + n * 2),
      high: Uint8List.sublistView(b, 2 + n * 2, 2 + n * 3),
    );
  }
}
