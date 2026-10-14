import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../models/loop_state.dart';
import 'loop_controls.dart';

/// AB 地点の微調整 UI（A 行 / A⇔B 入れ替え / B 行 / ステップ）。
///
/// 再生画面のガラス板コントローラー（縦）と横画面ドロワー（[compact]）で同じものを使う。
/// 各行: 色つきの A/B（タップで現在位置をその点にする）、時刻（タップでシーク）、− / +（ステップぶん動かす）。
/// 状態は持たず、変更はすべてコールバックで親に返す（テストで LoopNotifier を要らなくするため）。
class AbEditControls extends StatelessWidget {
  const AbEditControls({
    super.key,
    required this.loop,
    required this.step,
    required this.onStepChanged,
    required this.onSeek,
    required this.onPointA,
    required this.onPointB,
    required this.onSwap,
    this.onSetA,
    this.onSetB,
    this.compact = false,
  });

  final LoopState loop;

  /// 現在の微調整ステップ（秒）
  final double step;
  final ValueChanged<double> onStepChanged;

  /// 時刻タップでその位置へシークする
  final ValueChanged<Duration> onSeek;

  /// − / + で動かした後の値
  final ValueChanged<Duration> onPointA;
  final ValueChanged<Duration> onPointB;

  /// A > B のときの入れ替え
  final VoidCallback onSwap;

  /// 「現在位置を A/B にする」。動画未ロード時は null で無効化する
  final VoidCallback? onSetA;
  final VoidCallback? onSetB;

  /// 横ドロワーなど幅が狭い場所では小さく詰める
  final bool compact;

  static String stepLabel(double s) => s < 1 ? '${s}s' : '${s.toInt()}s';

  Duration get _stepDuration => Duration(milliseconds: (step * 1000).round());

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final needsSwap =
        loop.hasBothPoints && loop.pointA!.compareTo(loop.pointB!) > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PointRow(
          label: 'A',
          color: AppTheme.pointAColor,
          time: loop.pointA,
          compact: compact,
          onSet: onSetA,
          onTimeTap: loop.hasA ? () => onSeek(loop.pointA!) : null,
          onMinus: loop.hasA ? () => onPointA(loop.pointA! - _stepDuration) : null,
          onPlus: loop.hasA ? () => onPointA(loop.pointA! + _stepDuration) : null,
        ),
        // A > B のときだけ入れ替えボタンを出す
        if (needsSwap)
          // 押せる高さを 36px 以上に（以前は 24〜28px・10px の文字で押しにくかった）
          SizedBox(
            height: compact ? 36 : 40,
            child: TextButton.icon(
              onPressed: onSwap,
              icon: Icon(Icons.swap_vert,
                  size: AppIconSizes.s, color: Colors.amber.shade300),
              label: Text(compact ? 'A⇔B' : 'A と B を入れ替え',
                  style: textTheme.labelMedium!
                      .copyWith(color: Colors.amber.shade300)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              ),
            ),
          )
        else
          SizedBox(height: compact ? AppSpacing.sm : AppSpacing.md),
        _PointRow(
          label: 'B',
          color: AppTheme.pointBColor,
          time: loop.pointB,
          compact: compact,
          onSet: onSetB,
          onTimeTap: loop.hasB ? () => onSeek(loop.pointB!) : null,
          onMinus: loop.hasB ? () => onPointB(loop.pointB! - _stepDuration) : null,
          onPlus: loop.hasB ? () => onPointB(loop.pointB! + _stepDuration) : null,
        ),
        SizedBox(height: compact ? AppSpacing.sm : AppSpacing.lg - 2),
        _StepSelector(selected: step, onChanged: onStepChanged, compact: compact),
      ],
    );
  }
}

/// A/B の 1 行: 色つきの角丸（タップで「今を A/B」）、時刻、− / +
class _PointRow extends StatelessWidget {
  const _PointRow({
    required this.label,
    required this.color,
    required this.time,
    required this.compact,
    required this.onSet,
    required this.onTimeTap,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final Color color;
  final Duration? time;
  final bool compact;
  final VoidCallback? onSet;
  final VoidCallback? onTimeTap;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final box = compact ? 32.0 : 40.0;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35);
    return Row(
      children: [
        Tooltip(
          message: '今の位置を $label にする',
          child: Material(
            color: color.withValues(alpha: onSet == null ? 0.1 : 0.2),
            borderRadius: BorderRadius.circular(compact ? 9 : 12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onSet,
              child: SizedBox(
                width: box,
                height: box,
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: compact ? 13 : 15,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: compact ? AppSpacing.md : AppSpacing.lg),
        // 時刻（タップでシーク）
        InkWell(
          onTap: onTimeTap,
          borderRadius: AppRadius.borderSm,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs, vertical: 2),
            child: Text(
              TimeUtils.formatNullable(time),
              style: textTheme.titleMedium!.copyWith(
                fontSize: compact ? 14 : 18,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature('tnum')],
                color: time == null ? dim : null,
              ),
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          icon: Icon(Icons.remove_rounded, size: compact ? AppIconSizes.md : AppIconSizes.lg),
          onPressed: onMinus,
          tooltip: '$label を戻す',
          visualDensity: compact ? VisualDensity.compact : null,
        ),
        SizedBox(width: compact ? 0 : AppSpacing.xs),
        IconButton(
          icon: Icon(Icons.add_rounded, size: compact ? AppIconSizes.md : AppIconSizes.lg),
          onPressed: onPlus,
          tooltip: '$label を進める',
          visualDensity: compact ? VisualDensity.compact : null,
        ),
      ],
    );
  }
}

/// 微調整ステップ（0.001〜1秒）の選択行（ピル）
class _StepSelector extends StatelessWidget {
  const _StepSelector({
    required this.selected,
    required this.onChanged,
    required this.compact,
  });

  final double selected;
  final ValueChanged<double> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // 幅が足りなければ折り返す（横画面のドロワーで溢れていた）。
    // チップの高さは 32px 以上（以前は 20〜22px で押しにくかった）
    return Wrap(
      spacing: compact ? AppSpacing.xs : AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: EdgeInsets.only(right: compact ? AppSpacing.xs : AppSpacing.sm),
          child: Text('ステップ', style: textTheme.labelSmall),
        ),
        for (final s in LoopControls.steps)
          Material(
            color: selected == s
                ? AppTheme.accentGreen.withValues(alpha: 0.18)
                : scheme.onSurface.withValues(alpha: 0.08),
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onChanged(s),
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: compact ? AppSpacing.md + 2 : AppSpacing.lg,
                    vertical: compact ? AppSpacing.md : AppSpacing.md + 1),
                child: Text(
                  AbEditControls.stepLabel(s),
                  style: textTheme.labelSmall!.copyWith(
                    fontFeatures: const [FontFeature('tnum')],
                    color: selected == s
                        ? AppTheme.accentGreen
                        : scheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
