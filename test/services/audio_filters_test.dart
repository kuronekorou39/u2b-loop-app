import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';
import 'package:u2b_loop_app/services/audio_filters.dart';

void main() {
  test('スイープのカットオフは開いた所から閉じた所まで対数で下がる', () {
    expect(AudioFilters.sweepHz(0), closeTo(AudioFilters.sweepOpenHz, 1e-6));
    expect(AudioFilters.sweepHz(1), closeTo(AudioFilters.sweepClosedHz, 1e-6));
    final mid = AudioFilters.sweepHz(0.5);
    // 対数の中点 = 幾何平均
    expect(mid, closeTo(sqrt(AudioFilters.sweepOpenHz * AudioFilters.sweepClosedHz), 1));
    expect(AudioFilters.sweepHz(-1), closeTo(AudioFilters.sweepOpenHz, 1e-6));
    expect(AudioFilters.sweepHz(2), closeTo(AudioFilters.sweepClosedHz, 1e-6));
  });

  test('スイープの EQ: 開いた所は上端近くの狭い切れ込み、閉じるほど中心が下がり幅が広がる', () {
    final (f0, w0) = AudioFilters.sweepBand(AudioFilters.sweepOpenHz);
    expect(f0, lessThan(AudioFilters.sweepTopHz));
    expect(f0, greaterThan(AudioFilters.sweepOpenHz));
    expect(w0, lessThan(0.2));
    final (f1, w1) = AudioFilters.sweepBand(AudioFilters.sweepClosedHz);
    expect(f1, closeTo(sqrt(AudioFilters.sweepClosedHz * AudioFilters.sweepTopHz), 1));
    expect(w1, closeTo(6, 0.01)); // 250Hz〜16kHz = 6 オクターブ
    // 範囲外は端に丸める
    expect(AudioFilters.sweepBand(20000), AudioFilters.sweepBand(AudioFilters.sweepOpenHz));
    expect(AudioFilters.sweepBand(10), AudioFilters.sweepBand(AudioFilters.sweepClosedHz));
  });

  test('低音のランプ: 0 でそのまま、1 で切る', () {
    expect(AudioFilters.bassDb(0), 0);
    expect(AudioFilters.bassDb(1), AudioFilters.bassCutDb);
    expect(AudioFilters.bassDb(0.5), AudioFilters.bassCutDb / 2);
    expect(AudioFilters.bassDb(2), AudioFilters.bassCutDb);
  });

  test('TransitionEffect.fromName は不明なら既定（フィルタースイープ）', () {
    expect(TransitionEffect.fromName('riser'), TransitionEffect.riser);
    expect(TransitionEffect.fromName('none'), TransitionEffect.none);
    expect(TransitionEffect.fromName('x'), TransitionEffect.filterSweep);
    expect(TransitionEffect.fromName(null), TransitionEffect.filterSweep);
  });
}
