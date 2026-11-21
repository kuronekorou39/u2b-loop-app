import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/sfx_library.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';

void main() {
  test('フィルタ系: スイープはライザーにも付く', () {
    expect(TransitionEffect.filterSweep.sweepsOut, isTrue);
    expect(TransitionEffect.riser.sweepsOut, isTrue);
    expect(TransitionEffect.riserImpact.sweepsOut, isTrue);
    expect(TransitionEffect.brake.sweepsOut, isFalse);
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

  test('曲の音から作る演出（エコー・残響）は切替点で前の曲を止め、尾を切替点から鳴らす', () {
    for (final e in [TransitionEffect.echoTail, TransitionEffect.reverbTail]) {
      expect(e.atCutSfx, SfxRole.tail, reason: e.name);
      expect(e.endsAtCut, isTrue, reason: e.name);
      expect(e.cutsHard, isFalse, reason: '前の曲は切替点まで普通に進む（拍合わせも続ける）');
      expect(e.rendersAudio, isTrue, reason: e.name);
    }
    expect(TransitionEffect.spinback.rendersAudio, isTrue);
    expect(TransitionEffect.brake.rendersAudio, isFalse);
    expect(TransitionEffect.brake.endsAtCut, isTrue);
    expect(TransitionEffect.filterSweep.endsAtCut, isFalse);
  });

  test('控えめな効果音とフィルターイン', () {
    expect(TransitionEffect.reverseCymbal.leadInSfx, SfxRole.reverseCymbal);
    expect(TransitionEffect.crash.atCutSfx, SfxRole.crash);
    expect(TransitionEffect.crash.endsAtCut, isFalse, reason: '音量の曲線で重ねる');
    expect(TransitionEffect.filterIn.sweepsIn, isTrue);
    expect(TransitionEffect.filterIn.sweepsOut, isFalse);
    expect(TransitionEffect.filterIn.usesSfx, isFalse);
  });

  test('ボタンの下に出す短い名前は 5 文字まで', () {
    for (final e in TransitionEffect.values) {
      expect(e.short.length, lessThanOrEqualTo(5), reason: e.name);
    }
  });

  test('fromName は旧設定の名前をそのまま読める', () {
    expect(TransitionEffect.fromName('filterSweep'), TransitionEffect.filterSweep);
    expect(TransitionEffect.fromName('loopRoll'), TransitionEffect.loopRoll);
    expect(TransitionEffect.fromName('bogus'), TransitionEffect.defaultEffect);
    // 廃止したエコーアウトの保存値も既定に落ちる
    expect(TransitionEffect.fromName('echoOut'), TransitionEffect.defaultEffect);
  });
}
