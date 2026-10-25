import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/energy_profile.dart';

/// 音量の流れそのもの（2 秒ごとの dB）。3 分の曲を 3000 点（60ms/点）で表す
void main() {
  const durationMs = 180000;
  const n = 3000;

  test('2 秒ごとの平均 dB。頭 60 秒は −12dB、残りは 0dB、端数の区間も 1 点', () {
    final w = List<double>.generate(n, (i) => i * durationMs / n < 60000 ? 0.25 : 1.0);
    final c = EnergyProfile.curve(w, durationMs);
    expect(c.length, 90);
    expect(c[0], closeTo(-12, 0.5));
    expect(c[29], closeTo(-12, 0.5));
    // 平滑（250ms）の影響は境目の 1 点だけ
    expect(c[31], closeTo(0, 0.5));
    expect(c.last, closeTo(0, 0.5));
    // 端数（181 秒）なら 91 点
    expect(EnergyProfile.curve(w, durationMs + 1000).length, 91);
  });

  test('短すぎる・長さ不明なら空', () {
    expect(EnergyProfile.curve([0.5], durationMs), isEmpty);
    expect(EnergyProfile.curve(List.filled(n, 0.5), 0), isEmpty);
  });
}
