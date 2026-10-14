import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';
import 'package:u2b_loop_app/services/audio_filters.dart';

void main() {
  test('スイープのカットオフは開いた所から閉じた所まで対数で下がる', () {
    expect(AudioFilters.sweepHz(0), closeTo(AudioFilters.sweepOpenHz, 1e-6));
    expect(AudioFilters.sweepHz(1), closeTo(AudioFilters.sweepClosedHz, 1e-6));
    final mid = AudioFilters.sweepHz(0.5);
    // 対数の中点 = 幾何平均
    expect(mid, closeTo(2121.3, 1));
    expect(AudioFilters.sweepHz(-1), closeTo(AudioFilters.sweepOpenHz, 1e-6));
    expect(AudioFilters.sweepHz(2), closeTo(AudioFilters.sweepClosedHz, 1e-6));
  });

  test('TransitionEffect.fromName は不明なら なし', () {
    expect(TransitionEffect.fromName('echoOut'), TransitionEffect.echoOut);
    expect(TransitionEffect.fromName('filterSweep'), TransitionEffect.filterSweep);
    expect(TransitionEffect.fromName('x'), TransitionEffect.none);
    expect(TransitionEffect.fromName(null), TransitionEffect.none);
  });
}
