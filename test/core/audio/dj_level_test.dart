import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/crossfade_curve.dart';
import 'package:u2b_loop_app/core/audio/dj_level.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';

/// つなぎ方の段階は個々の設定から決まる（どれにも合わなければカスタム = null）
void main() {
  DjSettings s({
    bool autoMix = true,
    bool pro = false,
    CrossfadeCurve curve = CrossfadeCurve.defaultCurve,
    TransitionEffect effect = TransitionEffect.defaultEffect,
    bool on = true,
  }) =>
      DjSettings(
        autoMix: autoMix,
        pro: pro,
        curve: curve,
        effect: effect,
        bassSwap: on,
        tempoMatch: on,
        beatMatch: on,
        smartEntry: on,
        mixPointAlign: on,
      );

  test('今の既定は普通、ガチはおまかせ + ガチ', () {
    expect(DjLevel.of(s()), DjLevel.normal);
    expect(DjLevel.of(s(pro: true)), DjLevel.pro);
  });

  test('控えめ: おまかせなし・等パワー・演出なし・合わせない', () {
    expect(
        DjLevel.of(s(
            autoMix: false,
            curve: CrossfadeCurve.equalPower,
            effect: TransitionEffect.none,
            on: false)),
        DjLevel.gentle);
  });

  test('どれにも合わなければカスタム', () {
    expect(DjLevel.of(s(autoMix: false)), isNull);
    expect(
        DjLevel.of(s(
            autoMix: false,
            curve: CrossfadeCurve.cut,
            effect: TransitionEffect.none,
            on: false)),
        isNull);
  });
}
