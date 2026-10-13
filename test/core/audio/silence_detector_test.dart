import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/silence_detector.dart';

const _sr = 11025;

/// 前後に無音を付けた 440Hz のトーン
Int16List _toneWithSilence({
  required int leadingMs,
  required int toneMs,
  required int trailingMs,
  int noiseAmplitude = 0,
}) {
  final total = (leadingMs + toneMs + trailingMs) * _sr ~/ 1000;
  final y = Int16List(total);
  final start = leadingMs * _sr ~/ 1000;
  final end = start + toneMs * _sr ~/ 1000;
  final rng = Random(1);
  for (var i = 0; i < total; i++) {
    var v = 0.0;
    if (i >= start && i < end) v = 12000 * sin(2 * pi * 440 * i / _sr);
    if (noiseAmplitude > 0) v += (rng.nextDouble() * 2 - 1) * noiseAmplitude;
    y[i] = v.round().clamp(-32768, 32767);
  }
  return y;
}

void main() {
  test('曲頭・曲末の無音を 50ms 単位で当てる', () {
    final info = SilenceDetector.detect(
        _toneWithSilence(leadingMs: 1500, toneMs: 3000, trailingMs: 2200), _sr);
    expect(info.leadingMs, closeTo(1500, 60));
    expect(info.trailingMs, closeTo(2200, 60));
  });

  test('小さなノイズフロアは無音として扱う', () {
    final info = SilenceDetector.detect(
        _toneWithSilence(
            leadingMs: 1000, toneMs: 2000, trailingMs: 1000, noiseAmplitude: 30),
        _sr);
    expect(info.leadingMs, closeTo(1000, 60));
    expect(info.trailingMs, closeTo(1000, 60));
  });

  test('無音が無ければ 0', () {
    final info = SilenceDetector.detect(
        _toneWithSilence(leadingMs: 0, toneMs: 2000, trailingMs: 0), _sr);
    expect(info.leadingMs, 0);
    expect(info.trailingMs, 0);
  });

  test('曲末まで PCM が無い（長すぎて打ち切られた）場合、曲末は不明', () {
    final info = SilenceDetector.detect(
        _toneWithSilence(leadingMs: 500, toneMs: 2000, trailingMs: 1000), _sr,
        truncated: true);
    expect(info.leadingMs, closeTo(500, 60));
    expect(info.trailingMs, isNull);
  });

  test('全部無音なら全長を返す', () {
    final info = SilenceDetector.detect(Int16List(_sr * 2), _sr);
    expect(info.leadingMs, closeTo(2000, 60));
    expect(info.trailingMs, closeTo(2000, 60));
  });
}
