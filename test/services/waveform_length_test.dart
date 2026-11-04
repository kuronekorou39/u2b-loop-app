import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/services/waveform_service.dart';

/// 30 分を超える動画は波形を作らない（長さは分かるものから）
void main() {
  test('保存した長さ・プレイヤーの長さで判定、分からなければ作る', () {
    expect(WaveformService.tooLongForWaveform(durationMs: 31 * 60 * 1000), isTrue);
    expect(WaveformService.tooLongForWaveform(durationMs: 30 * 60 * 1000), isFalse);
    expect(
        WaveformService.tooLongForWaveform(playerDuration: const Duration(hours: 6)),
        isTrue);
    expect(WaveformService.tooLongForWaveform(), isFalse);
    // 保存した長さが先
    expect(
        WaveformService.tooLongForWaveform(
            durationMs: 4 * 60 * 1000, playerDuration: const Duration(hours: 1)),
        isFalse);
  });
}
