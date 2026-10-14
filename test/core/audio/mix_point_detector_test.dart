import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/mix_point_detector.dart';

/// 合成した包絡でミックス点の検出を確かめる。
/// 4 分の曲を 4000 点（60ms/点）で表す
void main() {
  const durationMs = 240000;
  const n = 4000;
  double msPer() => durationMs / n;

  /// [segments] は (終わりの秒, 振幅) の列。前の終わりから次の終わりまでその振幅
  List<double> envelope(List<(double, double)> segments) {
    final w = List<double>.filled(n, 0);
    var from = 0;
    for (final (endSec, amp) in segments) {
      final to = (endSec * 1000 / msPer()).round().clamp(0, n);
      for (var i = from; i < to; i++) {
        // 少し揺らす（±5%）
        w[i] = amp * (1 + 0.05 * ((i % 7) - 3) / 3);
      }
      from = to;
    }
    return w;
  }

  test('静かなイントロの後に大きくなる点をミックスインにする', () {
    // 0〜16s: -14dB(0.2)、16s〜: 0dB(1.0)
    final w = envelope([(16, 0.2), (240, 1.0)]);
    final p = MixPointDetector.fromWaveform(w, durationMs);
    expect(p.mixInMs, isNotNull);
    expect(p.mixInMs!, closeTo(16000, 400));
  });

  test('曲頭の無音は飛ばして探す', () {
    // 0〜3s 無音、3〜20s 小さい、20s〜 大きい
    final w = envelope([(3, 0.0), (20, 0.25), (240, 1.0)]);
    final p = MixPointDetector.fromWaveform(w, durationMs, leadingSilenceMs: 3000);
    expect(p.mixInMs!, closeTo(20000, 400));
  });

  test('ずっと同じ大きさならミックスインは無し', () {
    final w = envelope([(240, 0.8)]);
    final p = MixPointDetector.fromWaveform(w, durationMs);
    expect(p.mixInMs, isNull);
    expect(p.mixOutMs, isNull);
  });

  test('小さな揺れ（+3dB）では反応しない', () {
    final w = envelope([(16, 0.5), (240, 0.7)]);
    final p = MixPointDetector.fromWaveform(w, durationMs);
    expect(p.mixInMs, isNull);
  });

  test('曲末の落ち込みをミックスアウトにする', () {
    // 〜210s: 0dB、210s〜240s: -12dB のアウトロ
    final w = envelope([(210, 1.0), (240, 0.25)]);
    final p = MixPointDetector.fromWaveform(w, durationMs);
    expect(p.mixOutMs, isNotNull);
    expect(p.mixOutMs!, closeTo(210000, 400));
  });

  test('曲末の無音は範囲から外す（落ち込みの後に無音があっても同じ）', () {
    final w = envelope([(210, 1.0), (235, 0.25), (240, 0.0)]);
    final p = MixPointDetector.fromWaveform(w, durationMs, trailingSilenceMs: 5000);
    expect(p.mixOutMs!, closeTo(210000, 400));
  });

  test('一瞬のブレイク（すぐ戻る）はミックスアウトにしない', () {
    // 200s〜204s だけ小さく、その後は大きいまま
    final w = envelope([(200, 1.0), (204, 0.2), (240, 1.0)]);
    final p = MixPointDetector.fromWaveform(w, durationMs);
    expect(p.mixOutMs, isNull);
  });

  test('イントロが短すぎる（2 秒未満）ドロップは拾わない', () {
    final w = envelope([(1, 0.2), (240, 1.0)]);
    final p = MixPointDetector.fromWaveform(w, durationMs);
    expect(p.mixInMs, isNull);
  });

  test('短すぎる波形や長さ 0 では何も返さない', () {
    expect(MixPointDetector.fromWaveform(const [], durationMs), MixPoints.none);
    expect(MixPointDetector.fromWaveform(List.filled(10, 1.0), durationMs), MixPoints.none);
    expect(MixPointDetector.fromWaveform(List.filled(4000, 1.0), 0), MixPoints.none);
  });
}
