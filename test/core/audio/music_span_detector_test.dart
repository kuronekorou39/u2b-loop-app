import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/bpm_key_detector.dart';
import 'package:u2b_loop_app/core/audio/music_span_detector.dart';

const _sr = BpmKeyDetector.analysisSampleRate;

/// 指定 BPM のクリック音（短いノイズバースト）
Int16List _click(double bpm, double seconds) {
  final y = Int16List((_sr * seconds).round());
  final period = (_sr * 60 / bpm).round();
  final rng = Random(0);
  for (var i = 0; i + 300 < y.length; i += period) {
    for (var j = 0; j < 300; j++) {
      y[i + j] = ((rng.nextDouble() * 2 - 1) * (1 - j / 300) * 20000).round();
    }
  }
  return y;
}

/// トークの代わり: 音量がゆっくり不規則に揺れるノイズ（立ち上がりに周期が無い）
Int16List _talk(double seconds, {int seed = 1}) {
  final n = (_sr * seconds).round();
  final rng = Random(seed);
  final y = Int16List(n);
  var amp = 0.5;
  for (var i = 0; i < n; i++) {
    // 音量はランダムウォーク（0〜1 に収める）
    amp = (amp + (rng.nextDouble() - 0.5) * 0.002).clamp(0.0, 1.0);
    y[i] = (10000 * amp * (rng.nextDouble() * 2 - 1)).round();
  }
  return y;
}

/// 拍の無い和音（C の長三和音を伸ばす。音量と音程がゆっくり不規則に揺れ、少しノイズ。
/// 正弦波だけだと FFT の区切りと干渉して拍のような周期が出る）
Int16List _pad(double seconds) {
  final n = (_sr * seconds).round();
  final y = Int16List(n);
  final rng = Random(7);
  var amp = 0.7, drift = 0.0;
  final phases = [0.0, 0.0, 0.0, 0.0];
  const freqs = [130.81, 164.81, 196.0, 261.63];
  for (var i = 0; i < n; i++) {
    amp = (amp + (rng.nextDouble() - 0.5) * 0.0005).clamp(0.4, 1.0);
    drift = (drift + (rng.nextDouble() - 0.5) * 0.00002).clamp(-0.003, 0.003);
    var v = 0.0;
    for (var k = 0; k < freqs.length; k++) {
      phases[k] += 2 * pi * freqs[k] * (1 + drift) / _sr;
      v += sin(phases[k]);
    }
    y[i] = ((v / 4 * amp + 0.02 * (rng.nextDouble() * 2 - 1)) * 12000).round();
  }
  return y;
}

Int16List _concat(List<Int16List> parts) {
  final out = Int16List(parts.fold(0, (n, p) => n + p.length));
  var o = 0;
  for (final p in parts) {
    out.setAll(o, p);
    o += p.length;
  }
  return out;
}

MusicSpan _span(Int16List pcm) => MusicSpanDetector.detect(BpmKeyDetector.onsetEnvelope(pcm, _sr)!);

void main() {
  test('トーク → 曲 → トーク: 曲の範囲を 3 秒以内で見つける', () {
    final span = _span(_concat([_talk(30), _click(120, 60), _talk(20, seed: 2)]));
    expect(span.isMusic, isTrue);
    expect(span.startMs, closeTo(30000, 3000));
    expect(span.endMs, isNotNull);
    expect(span.endMs!, closeTo(90000, 3000));
  });

  test('トークだけなら曲ではない', () {
    expect(_span(_talk(90)).isMusic, isFalse);
  });

  test('全体が曲なら頭から終わりまで', () {
    final span = _span(_click(128, 90));
    expect(span.isMusic, isTrue);
    expect(span.startMs, 0);
    expect(span.endMs ?? 90000, greaterThan(86000));
  });

  test('曲が短すぎる（20 秒未満）なら曲ではない', () {
    expect(_span(_concat([_talk(40), _click(120, 12), _talk(40, seed: 3)])).isMusic, isFalse);
  });

  test('短すぎて判定できない動画は全体を曲として扱う', () {
    expect(_span(_click(120, 12)), same(MusicSpan.whole));
  });

  test('解析は曲の範囲だけで行い、拍の格子は動画の時刻に戻す', () {
    // 曲は 30 秒ちょうどから。120 BPM なので拍は 500ms ごと、動画の時刻で 30000 の倍数の位置
    final pcm = _concat([_talk(30), _click(120, 60), _talk(20, seed: 2)]);
    final r = BpmKeyDetector.analyze(pcm, _sr);
    expect(r.span.isMusic, isTrue);
    expect(r.bpm, closeTo(120, 1.5));
    final grid = r.beatGrid!;
    final phase = (30000 - grid.offsetMs) % grid.periodMs;
    expect(min(phase, grid.periodMs - phase), lessThan(30));
  });

  test('曲ではないなら BPM・キー・格子は空', () {
    final r = BpmKeyDetector.analyze(_talk(90), _sr);
    expect(r.span.isMusic, isFalse);
    expect(r.bpm, isNull);
    expect(r.key, isNull);
    expect(r.beatGrid, isNull);
  });

  test('保存する形: 頭とお尻の長さ。曲末まで届いていなければお尻は不明', () {
    const span = MusicSpan(isMusic: true, startMs: 30000, endMs: 90000);
    final info = MusicSpanInfo.of(span, lengthMs: 110000, truncated: false);
    expect(info.headMs, 30000);
    expect(info.tailMs, 20000);
    expect(MusicSpanInfo.of(span, lengthMs: 110000, truncated: true).tailMs, isNull);
    expect(MusicSpanInfo.of(MusicSpan.notMusic, lengthMs: 1, truncated: false).notMusic, isTrue);
  });

  test('拍がなくても和音があれば曲（キーだけ）。トークは曲ではないまま', () {
    final r = BpmKeyDetector.analyze(_pad(60), _sr);
    expect(r.span.isMusic, isTrue);
    expect(r.span.steadyBeat, isFalse, reason: '${r.span} bpm=${r.bpm}');
    expect(r.bpm, isNull);
    expect(r.beatGrid, isNull);
    expect(r.key, 'Cmaj');
    expect(BpmKeyDetector.analyze(_talk(60), _sr).span.isMusic, isFalse);
    expect(MusicSpanInfo.of(r.span, lengthMs: 60000, truncated: false).noSteadyBeat, isTrue);
  });
}
