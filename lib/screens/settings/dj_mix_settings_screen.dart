import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/transition_effect.dart';
import '../../providers/player_provider.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「DJ ミックス」: クロスフェードと、その中でだけ効く 5 つ
class DjMixSettingsScreen extends ConsumerWidget {
  const DjMixSettingsScreen({super.key});

  static String crossfadeLabel(int seconds) =>
      seconds == 0 ? 'オフ' : '$seconds秒';

  /// 設定トップの説明文に出す要約
  static String summary(WidgetRef ref) {
    final fade = ref.watch(crossfadeProvider);
    if (fade == 0) return 'クロスフェード オフ';
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
                  RadioListTile<CrossfadeCurve>(
                    value: c,
                    title: Text(c.label),
                    subtitle: Text(c.description),
                  ),
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
                  RadioListTile<TransitionEffect>(
                    value: e,
                    title: Text(e.label),
                    subtitle: Text(e.description),
                  ),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crossfade = ref.watch(crossfadeProvider);
    final on = crossfade != 0;
    const needsFade = 'クロスフェードをオンにすると使えます';
    final curve = ref.watch(crossfadeCurveProvider);
    final effect = ref.watch(transitionEffectProvider);

    return SettingsPage(
      title: 'DJ ミックス',
      children: [
        SettingsGroup(
          children: [
            // プレイリストで次曲がプリロード済みのとき、B点/終端の手前から重ねて鳴らす
            SettingsRow(
              icon: Icons.multitrack_audio,
              title: 'クロスフェード',
              subtitle: on
                  ? '${crossfadeLabel(crossfade)}かけて次の曲に重ねる'
                  : 'オフ。曲が終わってから次の曲へ',
              trailing: Text(crossfadeLabel(crossfade),
                  style: Theme.of(context).textTheme.bodyMedium),
              onTap: () => _pickCrossfade(context, ref),
            ),
          ],
        ),
        SettingsGroup(
          title: 'クロスフェード中の振る舞い',
          children: [
            // 対称な等パワーだけだと中間がぼやけるので、DJ らしい非対称やカットも選べる
            SettingsRow(
              icon: Icons.show_chart,
              title: 'つなぎ方',
              subtitle: on ? '${curve.label}: ${curve.description}' : needsFade,
              enabled: on,
              onTap: () => _pickCurve(context, ref),
            ),
            // 波形から求めたドロップが切り替わりに来るよう次曲の開始位置をずらし、出る曲はアウトロで切る
            SettingsSwitchRow(
              icon: Icons.trending_up,
              title: 'ドロップに合わせる',
              subtitle: on
                  ? '次の曲の盛り上がりが切り替わりに来るよう開始位置をずらし、前の曲はアウトロで切る'
                  : needsFade,
              value: ref.watch(mixPointAlignProvider),
              onChanged: on
                  ? (v) => ref.read(mixPointAlignProvider.notifier).value = v
                  : null,
            ),
            // 前後の曲の BPM が解析済みのときに次曲の速度を ±8% まで寄せ、交差後に元へ戻す
            SettingsSwitchRow(
              icon: Icons.speed,
              title: 'テンポ合わせ',
              subtitle: on ? '次曲の速度を前曲のテンポに寄せる' : needsFade,
              value: ref.watch(tempoMatchProvider),
              onChanged: on
                  ? (v) => ref.read(tempoMatchProvider.notifier).value = v
                  : null,
            ),
            // 解析した拍の格子で、重ね始めの拍の頭を揃え、交差中は速度を微調整して合わせ続ける
            SettingsSwitchRow(
              icon: Icons.align_horizontal_center,
              title: '拍合わせ',
              subtitle: on
                  ? '拍の頭を揃えて重ね、交差中は次曲の速度を微調整して合わせ続ける'
                  : needsFade,
              value: ref.watch(beatMatchProvider),
              onChanged: on
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
              subtitle: on ? '次の曲の低音を切って重ね、途中で前の曲と低音を入れ替える' : needsFade,
              value: ref.watch(bassSwapProvider),
              onChanged: on
                  ? (v) => ref.read(bassSwapProvider.notifier).value = v
                  : null,
            ),
            // 出る曲にかける演出。ベーススワップの位置から切替点までの間にかける
            SettingsRow(
              icon: Icons.auto_awesome,
              title: '切り替えの演出',
              subtitle: on ? '${effect.label}: ${effect.description}' : needsFade,
              enabled: on,
              onTap: () => _pickEffect(context, ref),
            ),
          ],
        ),
      ],
    );
  }
}
