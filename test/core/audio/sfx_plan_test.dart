import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/sfx_library.dart';
import 'package:u2b_loop_app/core/audio/sfx_plan.dart';
import 'package:u2b_loop_app/core/audio/transition_effect.dart';

/// 効果音の予定: ライザーは小節数で、頂点（終わり）が切替点に来ること
void main() {
  // 128 BPM: 1 拍 468.75ms、1 小節 1875ms
  const bar = 1875.0;
  const cut = 180000.0;

  SfxPlan planFor(TransitionEffect effect,
          {double fadeBars = 4, double outRate = 1, double? barMs = bar}) =>
      SfxPlan.plan(
        effect: effect,
        startMs: cut - fadeBars * bar,
        cutMs: cut,
        outRate: outRate,
        barMediaMs: barMs,
      );

  group('ライザー', () {
    test('交差 4 小節なら 4 小節前の小節頭から、8 秒の素材を 7.5 秒に縮めて切替点で終わる', () {
      final lead = planFor(TransitionEffect.riser).lead!;
      expect(lead.role, SfxRole.riser);
      expect(lead.bars, 4);
      expect(lead.atMs, closeTo(cut - 4 * bar, 1e-6));
      expect(lead.clip.durationMs, 8000);
      expect(lead.rate, closeTo(8000 / 7500, 1e-9));
      // 伸び縮み後の長さ = 小節数ぶんの実時間
      expect(lead.clip.durationMs / lead.rate, closeTo(4 * bar, 1e-6));
    });

    test('交差 2 小節なら 2 小節、1 小節なら 1 小節（交差より長いライザーは選ばない）', () {
      expect(planFor(TransitionEffect.riser, fadeBars: 2).lead!.bars, 2);
      final one = planFor(TransitionEffect.riser, fadeBars: 1).lead!;
      expect(one.bars, 1);
      expect(one.clip.durationMs, 2000);
      expect(one.rate, closeTo(2000 / bar, 1e-9));
    });

    test('8 小節が速度の範囲（0.5 倍）に収まらないテンポでは 4 小節に落とす', () {
      // 100 BPM: 1 小節 2400ms。8 小節 = 19.2 秒 → 8 秒の素材で 0.42 倍（範囲外）
      final plan = SfxPlan.plan(
        effect: TransitionEffect.riser,
        startMs: 0,
        cutMs: 8 * 2400,
        outRate: 1,
        barMediaMs: 2400,
      );
      expect(plan.lead!.bars, 4);
      expect(plan.lead!.rate, closeTo(8000 / 9600, 1e-9));
    });

    test('出る曲の速度が違えば、実時間に直して素材と速度を決める', () {
      // 1.25 倍速: 4 小節 7500ms（媒体）= 6000ms（実時間）→ 8 秒の素材を 1.33 倍
      final lead = planFor(TransitionEffect.riser, outRate: 1.25).lead!;
      expect(lead.atMs, closeTo(cut - 4 * bar, 1e-6));
      expect(lead.rate, closeTo(8000 / 6000, 1e-9));
    });

    test('拍の格子が無い曲は従来どおり（交差に収まる長さの素材を 1 倍速で、終わりを切替点に）', () {
      final lead = planFor(TransitionEffect.riser, barMs: null).lead!;
      expect(lead.bars, 0);
      expect(lead.rate, 1);
      // 交差 7.5 秒 → 8 秒の素材（1.15 倍まではみ出してよい）
      expect(lead.clip.durationMs, 8000);
      expect(lead.atMs, closeTo(cut - 8000, 1e-6));
    });
  });

  test('ライザー＋インパクト: インパクトは切替点、鳴らす順はライザー → インパクト', () {
    final plan = planFor(TransitionEffect.riserImpact);
    expect(plan.clips.map((c) => c.role), [SfxRole.riser, SfxRole.impact]);
    expect(plan.impact!.atMs, cut);
    expect(plan.impact!.rate, 1);
  });

  test('インパクト単独は切替点だけ', () {
    final plan = planFor(TransitionEffect.impact);
    expect(plan.lead, isNull);
    expect(plan.impact!.atMs, cut);
  });

  test('スピンバックは素材の長さのまま終わりを切替点に合わせる', () {
    final lead = planFor(TransitionEffect.spinback, outRate: 2).lead!;
    expect(lead.role, SfxRole.spinback);
    expect(lead.rate, 1);
    expect(lead.bars, 0);
    // 2 倍速の曲なので媒体の時計では 2 倍の長さ
    expect(lead.atMs, closeTo(cut - 2736 * 2, 1e-6));
  });

  test('効果音を使わない演出は空', () {
    expect(planFor(TransitionEffect.filterSweep).isEmpty, isTrue);
    expect(planFor(TransitionEffect.brake).cues, isEmpty);
  });

  test('同じ長さの素材は variant で順に回る', () {
    SfxCue at(int v) => SfxPlan.plan(
          effect: TransitionEffect.riser,
          startMs: cut - 4 * bar,
          cutMs: cut,
          outRate: 1,
          barMediaMs: bar,
          variant: v,
        ).lead!;
    expect(at(0).clip.asset, isNot(at(1).clip.asset));
    expect(at(3).clip.asset, at(0).clip.asset, reason: '8 秒のライザーは 3 本');
  });
}
