import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/transition_effect.dart';
import '../../providers/player_provider.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「DJ ミックス」: クロスフェードと、その中でだけ効く 5 つ
class DjMixSettingsScreen extends ConsumerWidget {
  const DjMixSettingsScreen({super.key});

  static String crossfadeLabel(int beats) => beats == 0 ? 'オフ' : '$beats拍';

  /// 設定トップの説明文に出す要約
  static String summary(WidgetRef ref) {
    final fade = ref.watch(crossfadeProvider);
    if (fade == 0) return 'クロスフェード オフ';
    if (ref.watch(autoMixProvider)) {
      return [
        'クロスフェード ${crossfadeLabel(fade)}',
        'おまかせ（曲に合わせて選ぶ）',
        if (ref.watch(mixPointAlignProvider)) 'ドロップに合わせる',
      ].join(' · ');
    }
    final parts = <String>[
      'クロスフェード ${crossfadeLabel(fade)}',
      ref.watch(crossfadeCurveProvider).label,
      if (ref.watch(mixPointAlignProvider)) 'ドロップに合わせる',
      if (ref.watch(tempoMatchProvider)) 'テンポ合わせ',
      if (ref.watch(beatMatchProvider)) '拍合わせ',
      if (ref.watch(bassSwapProvider)) 'ベーススワップ',
      if (ref.watch(transitionEffectProvider) != TransitionEffect.none)
        ref.watch(transitionEffectProvider).label,
    ];
    return parts.join(' · ');
  }

  Future<void> _pickCrossfade(BuildContext context, WidgetRef ref) async {
    final current = ref.read(crossfadeProvider);
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('クロスフェード'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in CrossfadeNotifier.options)
                  RadioListTile<int>(value: s, title: Text(crossfadeLabel(s))),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) ref.read(crossfadeProvider.notifier).value = picked;
  }

  Future<void> _pickCurve(BuildContext context, WidgetRef ref) async {
    final current = ref.read(crossfadeCurveProvider);
    final picked = await showDialog<CrossfadeCurve>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('つなぎ方'),
        children: [
          RadioGroup<CrossfadeCurve>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in CrossfadeCurve.values)
                  RadioListTile<CrossfadeCurve>(value: c, title: Text(c.label)),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) ref.read(crossfadeCurveProvider.notifier).value = picked;
  }

  Future<void> _pickEffect(BuildContext context, WidgetRef ref) async {
    final current = ref.read(transitionEffectProvider);
    final picked = await showDialog<TransitionEffect>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('切り替えの演出'),
        children: [
          RadioGroup<TransitionEffect>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in TransitionEffect.values)
                  RadioListTile<TransitionEffect>(value: e, title: Text(e.label)),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) {
      ref.read(transitionEffectProvider.notifier).value = picked;
    }
  }

  Future<void> _pickSfxLevel(BuildContext context, WidgetRef ref) async {
    final current = ref.read(sfxLevelProvider);
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('効果音の音量'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final db in SfxLevelNotifier.options)
                  RadioListTile<int>(
                      value: db, title: Text(SfxLevelNotifier.label(db))),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) ref.read(sfxLevelProvider.notifier).value = picked;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crossfade = ref.watch(crossfadeProvider);
    final on = crossfade != 0;
    const needsFade = 'クロスフェードをオンにすると使えます';
    final curve = ref.watch(crossfadeCurveProvider);
    final effect = ref.watch(transitionEffectProvider);
    final sfxLevel = ref.watch(sfxLevelProvider);
    final auto = ref.watch(autoMixProvider);
    // 手動の項目はおまかせを切ったときだけ
    final manual = on && !auto;
    const autoNote = 'おまかせ中は曲に合わせて自動で決まる';
    // おまかせはライザーなどを選ぶことがあるので、効果音の音量は常に触れる
    final sfxOn = on && (auto || effect.usesSfx);

    return SettingsPage(
      title: 'DJ ミックス',
      children: [
        SettingsGroup(
          children: [
            // プレイリストで次曲がプリロード済みのとき、B点/終端の手前から重ねて鳴らす
            SettingsRow(
              icon: Icons.multitrack_audio,
              title: 'クロスフェード',
              trailing: Text(crossfadeLabel(crossfade),
                  style: Theme.of(context).textTheme.bodyMedium),
              onTap: () => _pickCrossfade(context, ref),
            ),
          ],
        ),
        SettingsGroup(
          title: 'クロスフェード中の振る舞い',
          children: [
            // 2 曲の解析結果（テンポ・ビートの安定・ドロップ・音量の流れ）からレシピを選ぶ
            SettingsSwitchRow(
              icon: Icons.auto_mode,
              title: 'おまかせ',
              subtitle: on ? null : needsFade,
              value: auto,
              onChanged: on
                  ? (v) => ref.read(autoMixProvider.notifier).value = v
                  : null,
            ),
            // 対称な等パワーだけだと中間がぼやけるので、DJ らしい非対称やカットも選べる
            SettingsRow(
              icon: Icons.show_chart,
              title: 'つなぎ方',
              subtitle: manual
                  ? curve.label
                  : on
                      ? autoNote
                      : needsFade,
              enabled: manual,
              onTap: () => _pickCurve(context, ref),
            ),
            // 波形から求めたドロップが切り替わりに来るよう次曲の開始位置をずらし、出る曲はアウトロで切る
            SettingsSwitchRow(
              icon: Icons.trending_up,
              title: 'ドロップに合わせる',
              subtitle: on ? null : needsFade,
              value: ref.watch(mixPointAlignProvider),
              onChanged: on
                  ? (v) => ref.read(mixPointAlignProvider.notifier).value = v
                  : null,
            ),
            // 前後の曲の BPM が解析済みのときに次曲の速度を ±8% まで寄せ、交差後に元へ戻す
            SettingsSwitchRow(
              icon: Icons.speed,
              title: 'テンポ合わせ',
              subtitle: manual
                  ? null
                  : on
                      ? autoNote
                      : needsFade,
              value: ref.watch(tempoMatchProvider),
              onChanged: manual
                  ? (v) => ref.read(tempoMatchProvider.notifier).value = v
                  : null,
            ),
            // 解析した拍の格子で、重ね始めの拍の頭を揃え、交差中は速度を微調整して合わせ続ける
            SettingsSwitchRow(
              icon: Icons.align_horizontal_center,
              title: '拍合わせ',
              subtitle: manual
                  ? null
                  : on
                      ? autoNote
                      : needsFade,
              value: ref.watch(beatMatchProvider),
              onChanged: manual
                  ? (v) => ref.read(beatMatchProvider.notifier).value = v
                  : null,
            ),
          ],
        ),
        SettingsGroup(
          title: '低音と演出',
          children: [
            // 低音の衝突（混ざる部分がぼやける主因）を避ける DJ の定石
            SettingsSwitchRow(
              icon: Icons.graphic_eq,
              title: 'ベーススワップ',
              subtitle: manual
                  ? null
                  : on
                      ? autoNote
                      : needsFade,
              value: ref.watch(bassSwapProvider),
              onChanged: manual
                  ? (v) => ref.read(bassSwapProvider.notifier).value = v
                  : null,
            ),
            // 出る曲にかける演出。ベーススワップの位置から切替点までの間にかける
            SettingsRow(
              icon: Icons.auto_awesome,
              title: '切り替えの演出',
              subtitle: manual
                  ? effect.label
                  : on
                      ? autoNote
                      : needsFade,
              enabled: manual,
              onTap: () => _pickEffect(context, ref),
            ),
            // 効果音（ライザー / インパクト / スピンバック）の曲に対する大きさ
            SettingsRow(
              icon: Icons.campaign,
              title: '効果音の音量',
              subtitle: sfxOn
                  ? null
                  : on
                      ? '効果音を使う演出で使えます'
                      : needsFade,
              enabled: sfxOn,
              trailing: Text(SfxLevelNotifier.label(sfxLevel),
                  style: Theme.of(context).textTheme.bodyMedium),
              onTap: () => _pickSfxLevel(context, ref),
            ),
          ],
        ),
      ],
    );
  }
}
