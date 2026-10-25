import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/transition_effect.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/player_provider.dart';
import '../../screens/settings/dj_mix_settings_screen.dart';
import 'sfx_offset_stepper.dart';

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
    final sfxLevel = ref.watch(sfxLevelProvider);
    final auto = ref.watch(autoMixProvider);
    final manual = on && !auto;
    const autoNote = 'おまかせ中は曲に合わせて自動で決まる';
    final sfxOn = on && (auto || effect.usesSfx);
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
            ),
            _Chips<int>(
              values: CrossfadeNotifier.options,
              selected: crossfade,
              label: DjMixSettingsScreen.crossfadeLabel,
              onSelected: (v) => ref.read(crossfadeProvider.notifier).value = v,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_mode),
              title: const Text('おまかせ'),
              value: auto,
              onChanged: on
                  ? (v) => ref.read(autoMixProvider.notifier).value = v
                  : null,
            ),
            const Divider(),
            _SectionLabel(
              icon: Icons.show_chart,
              label: 'つなぎ方',
              hint: manual
                  ? null
                  : on
                      ? autoNote
                      : 'クロスフェードをオンにすると使えます',
              enabled: manual,
            ),
            _Chips<CrossfadeCurve>(
              values: CrossfadeCurve.values,
              selected: curve,
              label: (c) => c.label,
              onSelected: manual
                  ? (v) => ref.read(crossfadeCurveProvider.notifier).value = v
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.trending_up),
              title: const Text('ドロップに合わせる'),
              value: ref.watch(mixPointAlignProvider),
              onChanged: on
                  ? (v) => ref.read(mixPointAlignProvider.notifier).value = v
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.login),
              title: const Text('入り口を選ぶ'),
              value: ref.watch(smartEntryProvider),
              onChanged: on
                  ? (v) => ref.read(smartEntryProvider.notifier).value = v
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.speed),
              title: const Text('テンポ合わせ'),
              value: ref.watch(tempoMatchProvider),
              onChanged: manual
                  ? (v) => ref.read(tempoMatchProvider.notifier).value = v
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.align_horizontal_center),
              title: const Text('拍合わせ'),
              value: ref.watch(beatMatchProvider),
              onChanged: manual
                  ? (v) => ref.read(beatMatchProvider.notifier).value = v
                  : null,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.view_week_outlined),
              title: const Text('拍の線を表示'),
              value: ref.watch(showBeatLinesProvider),
              onChanged: (v) =>
                  ref.read(showBeatLinesProvider.notifier).value = v,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.ssid_chart),
              title: const Text('音量の線を表示'),
              value: ref.watch(showMixCurvesProvider),
              onChanged: (v) =>
                  ref.read(showMixCurvesProvider.notifier).value = v,
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.graphic_eq),
              title: const Text('ベーススワップ'),
              value: ref.watch(bassSwapProvider),
              onChanged: manual
                  ? (v) => ref.read(bassSwapProvider.notifier).value = v
                  : null,
            ),
            _SectionLabel(
              icon: Icons.auto_awesome,
              label: '切り替えの演出',
              hint: manual
                  ? null
                  : on
                      ? autoNote
                      : 'クロスフェードをオンにすると使えます',
              enabled: manual,
            ),
            _Chips<TransitionEffect>(
              values: TransitionEffect.values,
              selected: effect,
              label: (e) => e.label,
              onSelected: manual
                  ? (v) =>
                      ref.read(transitionEffectProvider.notifier).value = v
                  : null,
            ),
            _SectionLabel(
              icon: Icons.campaign,
              label: '効果音の音量',
              hint: sfxOn ? null : '効果音を使う演出で使えます',
              enabled: sfxOn,
            ),
            _Chips<int>(
              values: SfxLevelNotifier.options,
              selected: sfxLevel,
              label: SfxLevelNotifier.label,
              onSelected: sfxOn
                  ? (v) => ref.read(sfxLevelProvider.notifier).value = v
                  : null,
            ),
            _SectionLabel(
              icon: Icons.timer_outlined,
              label: '効果音のタイミング',
              hint: sfxOn ? null : '効果音を使う演出で使えます',
              enabled: sfxOn,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.xs, AppSpacing.xl, AppSpacing.xs),
              child: SfxOffsetStepper(enabled: sfxOn),
            ),
          ],
        ),
      ),
    );
  }
}

/// 見出し（アイコン + 名前）。[hint] は触れない理由だけ（説明は出さない）
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.icon,
    required this.label,
    this.hint,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final String? hint;
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
                  if (hint != null)
                    Text(hint!,
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
