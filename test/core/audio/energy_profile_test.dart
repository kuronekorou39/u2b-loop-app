import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/energy_profile.dart';

/// 合成した包絡で音量の流れの要約を確かめる。4 分の曲を 4000 点（60ms/点）で表す
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
        w[i] = amp;
      }
      from = to;
    }
    return w;
  }

  test('頭と末尾の平均、急に終わる曲は endFade ≈ 0', () {
    // 頭 30 秒は 0.25（−12dB）、残りは 1.0（0dB）、最後まで鳴って急に終わる
    final w = envelope([(30, 0.25), (240, 1.0)]);
    final e = EnergyProfile.fromWaveform(w, durationMs);
    expect(e.headDb, closeTo(-12, 0.5));
    expect(e.tailDb, closeTo(0, 0.5));
    expect(e.endFadeDb, closeTo(0, 0.5));
    expect(e.dropDb, isNull);
  });

  test('フェードアウトで終わる曲は endFade が大きく負', () {
    // 最後の 10 秒だけ 0.1（−20dB）。曲末の無音は範囲から外れる
    final w = envelope([(225, 1.0), (235, 0.1), (240, 0.0)]);
    final e = EnergyProfile.fromWaveform(w, durationMs, trailingSilenceMs: 5000);
    expect(e.endFadeDb, lessThan(-15));
  });

  test('ミックスイン点の跳ね幅', () {
    // 30 秒で 0.25 → 1.0（+12dB）
    final w = envelope([(30, 0.25), (240, 1.0)]);
    final e = EnergyProfile.fromWaveform(w, durationMs, mixInMs: 30000);
    expect(e.dropDb, closeTo(12, 1));
  });

  test('曲頭の無音は頭の平均に入れない', () {
    final w = envelope([(5, 0.0), (35, 0.5), (240, 1.0)]);
    final e = EnergyProfile.fromWaveform(w, durationMs, leadingSilenceMs: 5000);
    expect(e.headDb, closeTo(-6, 0.5));
  });

  test('短すぎる波形は空', () {
    expect(EnergyProfile.fromWaveform(const [0.5, 0.5], 1000).isEmpty, isTrue);
    expect(EnergyProfile.fromWaveform(List.filled(4000, 0.0), durationMs).isEmpty, isTrue);
  });
}
