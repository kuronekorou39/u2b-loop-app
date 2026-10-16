import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/loudness.dart';

void main() {
  test('measureDb: フルスケールの正弦波（RMS 23170）は −3dBFS、無音は null', () {
    expect(Loudness.measureDb(List.filled(100, 23170)), closeTo(-3.0, 0.05));
    expect(Loudness.measureDb(List.filled(100, 3277)), closeTo(-20.0, 0.05));
    expect(Loudness.measureDb(const []), isNull);
    expect(Loudness.measureDb(List.filled(10, 0)), isNull);
  });

  test('gain: 目標より大きい曲は下げ、小さい曲は上げない、下げ幅は −12dB まで', () {
    expect(Loudness.gainDb(-14), 0);
    expect(Loudness.gainDb(-8), -6);
    expect(Loudness.gainDb(-20), 0);
    expect(Loudness.gainDb(2), Loudness.maxCutDb);
    expect(Loudness.gainDb(null), 0);
    expect(Loudness.gain(-8), closeTo(0.501, 0.001));
    expect(Loudness.volumeFor(-8), closeTo(50.1, 0.1));
    expect(Loudness.volumeFor(null), 100);
    expect(Loudness.volumeFor(-8, base: 50), closeTo(25.06, 0.1));
  });

  test('carry: 今の補正を外して次の補正をかけ直す（100 を超えない）', () {
    // 大きい曲（50%）→ ふつうの曲（100%）
    expect(Loudness.carry(50.1, -8, -14), closeTo(100, 0.2));
    // ふつうの曲でスライダー 80 → 大きい曲は 40
    expect(Loudness.carry(80, -14, -8), closeTo(40.1, 0.1));
    expect(Loudness.carry(100, null, null), 100);
    expect(Loudness.carry(90, -8, -14), 100);
  });
}
