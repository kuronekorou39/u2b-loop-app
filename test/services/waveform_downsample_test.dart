import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/energy_profile.dart';
import 'package:u2b_loop_app/services/waveform_service.dart';

/// デコードの塊（AAC は 1024 サンプルごと）を、画面と解析に使う 4000 点へ間引く
void main() {
  test('元の値が多いときは区間ごとの最大', () {
    final w = WaveformService.downsampleAndNormalize([1, 5, 2, 8, 3, 4], 3);
    expect(w, [5 / 8, 1.0, 4 / 8]);
  });

  test('短い曲（元の値が点より少ない）でも 0 の点ができない', () {
    // 44 秒の曲 = 塊 1897 個 < 4000 点。以前は半分以上の点が 0 になっていた
    final w = WaveformService.downsampleAndNormalize(List.filled(1897, 1000), 4000);
    expect(w, hasLength(4000));
    expect(w.every((v) => v == 1.0), isTrue);
  });

  test('短い曲の音量の流れが、穴で下がって見えない', () {
    final w = WaveformService.downsampleAndNormalize(List.filled(1897, 1000), 4000);
    final e = EnergyProfile.fromWaveform(w, 44000);
    expect(e.headDb, closeTo(0, 0.01));
    expect(e.tailDb, closeTo(0, 0.01));
  });

  test('空なら 0 で埋める', () {
    expect(WaveformService.downsampleAndNormalize(const [], 4), [0, 0, 0, 0]);
  });
}
