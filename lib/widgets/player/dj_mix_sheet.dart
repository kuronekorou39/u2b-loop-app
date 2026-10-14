import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/transition_effect.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/player_provider.dart';
import '../../screens/settings/dj_mix_settings_screen.dart';

/// 再生画面から開く「DJ ミックス」のシート。
///
/// 設定の DJ ミックスのページと同じ値（クロスフェード / つなぎ方 / ドロップに合わせる /
/// テンポ合わせ / ベーススワップ / 切り替えの演出）を、聴きながらその場で変えるためのもの。
/// 変更は次の切り替わりから効く（PlaylistEngine は交差を始めるときに設定を読む）。
/// クロスフェードがオフのときは他の項目は触れない
class DjMixSheet extends ConsumerWidget {
  const DjMixSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const DjMixSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crossfade = ref.watch(crossfadeProvider);
    final on = crossfade != 0;
    final curve = ref.watch(crossfadeCurveProvider);
    final effect = ref.watch(transitionEffectProvider);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset + AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel(
              icon: Icons.multitrack_audio,
              label: 'クロスフェード',
              hint: '次の曲に重ねる長さ',
            ),
            _Chips<int>(
              values: CrossfadeNotifier.options,
              selected: crossfade,
              label: DjMixSettingsScreen.crossfadeLabel,
              onSelected: (v) => ref.read(crossfadeProvider.notifier).value = v,
            ),
            const Divider(),
            _SectionLabel(
              icon: Icons.show_chart,
              label: 'つなぎ方',
              hint: on ? curve.description : 'クロスフェードをオンにすると使えます',
              enabled: on,
            ),
            _Chips<CrossfadeCurve>(
              values: CrossfadeCurve.values,
              selected: curve,
              label: (c) => c.label,
              onSelected: on
                  ? (v) => ref.read(crossfadeCurveProvider.notifier).value = v
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.trending_up),
              title: const Text('ドロップに合わせる'),
              subtitle: const Text('次の曲の盛り上がりが切り替わりに来るようにする'),
              value: ref.watch(mixPointAlignProvider),
              onChanged: on
                  ? (v) => ref.read(mixPointAlignProvider.notifier).value = v
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.speed),
              title: const Text('テンポ合わせ'),
              subtitle: const Text('次曲の速度を前曲のテンポに寄せる'),
              value: ref.watch(tempoMatchProvider),
              onChanged: on
                  ? (v) => ref.read(tempoMatchProvider.notifier).value = v
                  : null,
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.graphic_eq),
              title: const Text('ベーススワップ'),
              subtitle: const Text('次の曲の低音を切って重ね、途中で低音を入れ替える'),
              value: ref.watch(bassSwapProvider),
              onChanged: on
                  ? (v) => ref.read(bassSwapProvider.notifier).value = v
                  : null,
            ),
            _SectionLabel(
              icon: Icons.auto_awesome,
              label: '切り替えの演出',
              hint: on ? effect.description : 'クロスフェードをオンにすると使えます',
              enabled: on,
            ),
            _Chips<TransitionEffect>(
              values: TransitionEffect.values,
              selected: effect,
              label: (e) => e.label,
              onSelected: on
                  ? (v) =>
                      ref.read(transitionEffectProvider.notifier).value = v
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「その他」シートの速度の行と同じ見た目の見出し（アイコン + 名前 + 説明）
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.icon,
    required this.label,
    required this.hint,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final String hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, 0),
        child: Row(
          children: [
            Icon(icon, size: AppIconSizes.lg),
            const SizedBox(width: AppSpacing.xl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: textTheme.bodyLarge),
                  Text(hint,
                      style: textTheme.labelSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chips<T> extends StatelessWidget {
  const _Chips({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;

  /// null なら全部無効
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.sm,
        children: [
          for (final v in values)
            ChoiceChip(
              label: Text(label(v)),
              selected: v == selected,
              onSelected:
                  onSelected == null ? null : (_) => onSelected!(v),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
