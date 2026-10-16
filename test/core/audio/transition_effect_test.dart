import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/sfx_library.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';

void main() {
  test('フィルタ系: スイープはライザーにも付く、エコーはエコーアウトだけ', () {
    expect(TransitionEffect.filterSweep.sweepsOut, isTrue);
    expect(TransitionEffect.riser.sweepsOut, isTrue);
    expect(TransitionEffect.riserImpact.sweepsOut, isTrue);
    expect(TransitionEffect.echoOut.sweepsOut, isFalse);
    expect(TransitionEffect.brake.sweepsOut, isFalse);
    expect(TransitionEffect.echoOut.echoesOut, isTrue);
    expect(TransitionEffect.values.where((e) => e.echoesOut).length, 1);
  });

  test('効果音: 先行して鳴らすもの・切替点で鳴らすもの', () {
    expect(TransitionEffect.riser.leadInSfx, SfxRole.riser);
    expect(TransitionEffect.riserImpact.leadInSfx, SfxRole.riser);
    expect(TransitionEffect.spinback.leadInSfx, SfxRole.spinback);
    expect(TransitionEffect.impact.leadInSfx, isNull);
    expect(TransitionEffect.riserImpact.impactAtCut, isTrue);
    expect(TransitionEffect.impact.impactAtCut, isTrue);
    expect(TransitionEffect.riser.impactAtCut, isFalse);
    for (final e in TransitionEffect.values) {
      expect(e.usesSfx, e.leadInSfx != null || e.impactAtCut, reason: e.name);
    }
    expect(TransitionEffect.filterSweep.usesSfx, isFalse);
    expect(TransitionEffect.brake.usesSfx, isFalse);
    expect(TransitionEffect.loopRoll.usesSfx, isFalse);
  });

  test('トリック系は切替点まで前の曲だけ', () {
    expect(TransitionEffect.brake.cutsHard, isTrue);
    expect(TransitionEffect.spinback.cutsHard, isTrue);
    expect(TransitionEffect.loopRoll.cutsHard, isTrue);
    expect(TransitionEffect.riserImpact.cutsHard, isFalse);
    expect(TransitionEffect.none.cutsHard, isFalse);
  });

  test('fromName は旧設定の名前をそのまま読める', () {
    expect(TransitionEffect.fromName('filterSweep'), TransitionEffect.filterSweep);
    expect(TransitionEffect.fromName('loopRoll'), TransitionEffect.loopRoll);
    expect(TransitionEffect.fromName('bogus'), TransitionEffect.defaultEffect);
  });
}
