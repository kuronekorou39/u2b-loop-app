import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/dj_level.dart';
import '../../core/audio/transition_effect.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sheets.dart';
import '../../providers/player_provider.dart';
import '../../screens/settings/dj_mix_settings_screen.dart';
import 'more_tile.dart';
import 'sfx_offset_stepper.dart';

/// 再生画面から開く「DJ ミックス」のポップアップ。
///
/// 設定の DJ ミックスのページと同じ値（クロスフェード / つなぎ方 / ドロップに合わせる /
/// テンポ合わせ / ベーススワップ / 切り替えの演出）を、聴きながらその場で変えるためのもの。
/// 変更は次の切り替わりから効く（PlaylistEngine は交差を始めるときに設定を読む）。
///
/// スクロールせずに収まるよう、上にレベル、真ん中に小さめのタイル（オンオフは光る、
/// 候補から選ぶものはプルダウン）、下に効果音のタイミング。
/// 拍の線・音量の線の表示はデッキの板の下の行にあるのでここには無い。
/// クロスフェードがオフのときは他の項目は触れない。おまかせ中に手動の項目を変えるとカスタムに移る
class DjMixSheet extends ConsumerWidget {
  const DjMixSheet({super.key});

  static Future<void> show(BuildContext context) {
    return AppSheets.popup<void>(context, builder: (_) => const DjMixSheet());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final crossfade = ref.watch(crossfadeProvider);
    final on = crossfade != 0;
    final effect = ref.watch(transitionEffectProvider);
    final auto = ref.watch(autoMixProvider);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset + AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Row(
                children: [
                  Icon(Icons.tune, size: AppIconSizes.lg),
                  SizedBox(width: AppSpacing.lg),
                  Expanded(child: DjLevelChips()),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            MoreTileGrid(
              dense: true,
              tiles: [
                PickerTile<int>(
                  icon: Icons.multitrack_audio,
                  label: 'クロスフェード',
                  values: CrossfadeNotifier.options,
                  selected: crossfade,
                  labelOf: DjMixSettingsScreen.crossfadeLabel,
                  onPicked: (v) =>
                      ref.read(crossfadeProvider.notifier).value = v,
                  dense: true,
                ),
                MoreTile(
                  icon: Icons.auto_mode,
                  label: 'おまかせ',
                  active: auto,
                  enabled: on,
                  dense: true,
                  onTap: () => ref.read(autoMixProvider.notifier).value = !auto,
                ),
                PickerTile<CrossfadeCurve>(
                  icon: Icons.show_chart,
                  label: 'つなぎ方',
                  values: CrossfadeCurve.values,
                  selected: ref.watch(crossfadeCurveProvider),
                  labelOf: (c) => c.label,
                  onPicked: (v) {
                    leaveAutoMix(ref);
                    ref.read(crossfadeCurveProvider.notifier).value = v;
                  },
                  enabled: on,
                  dense: true,
                ),
                _Toggle(
                  icon: Icons.trending_up,
                  label: 'ドロップ合わせ',
                  value: ref.watch(mixPointAlignProvider),
                  onChanged: (v) =>
                      ref.read(mixPointAlignProvider.notifier).value = v,
                  enabled: on,
                ),
                _Toggle(
                  icon: Icons.login,
                  label: '出入り口',
                  value: ref.watch(smartEntryProvider),
                  onChanged: (v) =>
                      ref.read(smartEntryProvider.notifier).value = v,
                  enabled: on,
                ),
                _Toggle(
                  icon: Icons.speed,
                  label: 'テンポ合わせ',
                  value: ref.watch(tempoMatchProvider),
                  onChanged: (v) {
                    leaveAutoMix(ref);
                    ref.read(tempoMatchProvider.notifier).value = v;
                  },
                  enabled: on,
                ),
                _Toggle(
                  icon: Icons.align_horizontal_center,
                  label: '拍合わせ',
                  value: ref.watch(beatMatchProvider),
                  onChanged: (v) {
                    leaveAutoMix(ref);
                    ref.read(beatMatchProvider.notifier).value = v;
                  },
                  enabled: on,
                ),
                _Toggle(
                  icon: Icons.graphic_eq,
                  label: 'ベーススワップ',
                  value: ref.watch(bassSwapProvider),
                  onChanged: (v) {
                    leaveAutoMix(ref);
                    ref.read(bassSwapProvider.notifier).value = v;
                  },
                  enabled: on,
                ),
                PickerTile<TransitionEffect>(
                  icon: Icons.auto_awesome,
                  label: '演出',
                  values: TransitionEffect.values,
                  selected: effect,
                  labelOf: (e) => e.label,
                  onPicked: (v) {
                    leaveAutoMix(ref);
                    ref.read(transitionEffectProvider.notifier).value = v;
                  },
                  enabled: on,
                  dense: true,
                ),
                PickerTile<int>(
                  icon: Icons.campaign,
                  label: '効果音',
                  values: SfxLevelNotifier.options,
                  selected: ref.watch(sfxLevelProvider),
                  labelOf: SfxLevelNotifier.label,
                  onPicked: (v) =>
                      ref.read(sfxLevelProvider.notifier).value = v,
                  enabled: on,
                  dense: true,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // 効果音のタイミングの補正（−/+ なのでタイルにはしない）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Row(
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: AppIconSizes.lg,
                    color: on ? null : AppTheme.muted(context),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Text(
                      '効果音のずれ',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        color: on ? null : AppTheme.muted(context),
                      ),
                    ),
                  ),
                  SfxOffsetStepper(enabled: on),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// つなぎ方のレベル（控えめ・普通・ガチ・カスタム）の 4 つのボタン。設定の DJ ミックスのページと共用。
///
/// 下の個々の設定をまとめて変えるプリセットなので、どれも同じように押せる見た目にする
/// （選ばれていないものを灰色にしない）。今の設定と一致するものだけ緑の枠と文字。
/// どれとも一致しなければカスタム。カスタムを押すとおまかせを切り、個々の設定は今のまま
/// （個々の設定は制限せず、おまかせ中に手で変えてもカスタムに移る）
class DjLevelChips extends ConsumerWidget {
  const DjLevelChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final level = ref.watch(djLevelProvider);
    final radius = BorderRadius.circular(AppRadius.lg);
    return Row(
      children: [
        // null = カスタム
        for (final (i, l) in <DjLevel?>[...DjLevel.values, null].indexed) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Material(
              color: onSurface.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: radius,
                side: l == level
                    ? const BorderSide(color: AppTheme.accentGreen, width: 1.5)
                    : BorderSide.none,
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () =>
                    l == null ? applyDjCustom(ref) : applyDjLevel(ref, l),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text(
                    DjMixSettingsScreen.levelLabel(l),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: l == level ? AppTheme.accentGreen : onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// オンオフの設定 1 つ分のタイル（押すと反転して保存）
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.enabled,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => MoreTile(
    icon: icon,
    label: label,
    active: value,
    enabled: enabled,
    dense: true,
    onTap: () => onChanged(!value),
  );
}
