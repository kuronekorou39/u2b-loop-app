import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_state.dart';
import '../../providers/loop_provider.dart';
import 'loop_controls.dart';

/// AB地点の微調整UI（A行 / A⇔B入れ替え / B行 / ステップ選択）。
///
/// 縦レイアウトと横ドロワーで同じものを使う。
/// 以前は player_screen 内に約120行が2箇所コピペされており、
/// A⇔Bボタンの文言や余白がすでに食い違っていた。
class AbEditControls extends StatelessWidget {
  const AbEditControls({
    super.key,
    required this.loop,
    required this.notifier,
    required this.step,
    required this.onStepChanged,
    required this.onSeek,
    this.onSetA,
    this.onSetB,
    this.compact = false,
  });

  final LoopState loop;
  final LoopNotifier notifier;

  /// 現在の微調整ステップ（秒）
  final double step;
  final ValueChanged<double> onStepChanged;

  /// 時刻タップでその位置へシークする
  final ValueChanged<Duration> onSeek;

  /// 「現在位置をA/Bにする」。動画未ロード時は null で無効化する
  final VoidCallback? onSetA;
  final VoidCallback? onSetB;

  /// 横ドロワーなど幅が狭い場所では文言を詰める
  final bool compact;

  static String stepLabel(double s) => s < 1 ? '${s}s' : '${s.toInt()}s';

  Duration get _stepDuration => Duration(milliseconds: (step * 1000).round());

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LoopControls.buildPointRow(
          label: 'A',
          color: AppTheme.pointAColor,
          time: loop.pointA,
          stepLabel: stepLabel(step),
          onSet: onSetA,
          onTimeTap: loop.hasA ? () => onSeek(loop.pointA!) : null,
          onMinus: () {
            if (loop.hasA) notifier.setPointA(loop.pointA! - _stepDuration);
          },
          onPlus: () {
            if (loop.hasA) notifier.setPointA(loop.pointA! + _stepDuration);
          },
        ),
        // A > B のときだけ入れ替えボタンを出す
        if (loop.hasBothPoints && loop.pointA!.compareTo(loop.pointB!) > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: SizedBox(
              height: 24,
              child: TextButton.icon(
                onPressed: notifier.swapPoints,
                icon: Icon(Icons.swap_vert,
                    size: AppIconSizes.xs, color: Colors.amber.shade300),
                label: Text(compact ? 'A⇔B' : 'A⇔B 入れ替え',
                    style: textTheme.labelSmall!.copyWith(
                        fontSize: 10, color: Colors.amber.shade300)),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          )
        else
          const SizedBox(height: AppSpacing.sm),
        LoopControls.buildPointRow(
          label: 'B',
          color: AppTheme.pointBColor,
          time: loop.pointB,
          stepLabel: stepLabel(step),
          onSet: onSetB,
          onTimeTap: loop.hasB ? () => onSeek(loop.pointB!) : null,
          onMinus: () {
            if (loop.hasB) notifier.setPointB(loop.pointB! - _stepDuration);
          },
          onPlus: () {
            if (loop.hasB) notifier.setPointB(loop.pointB! + _stepDuration);
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        _StepSelector(
            selected: step, onChanged: onStepChanged, textTheme: textTheme),
      ],
    );
  }
}

/// 微調整ステップ（0.001〜1秒）の選択行
class _StepSelector extends StatelessWidget {
  const _StepSelector({
    required this.selected,
    required this.onChanged,
    required this.textTheme,
  });

  final double selected;
  final ValueChanged<double> onChanged;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text('Step',
            style: textTheme.labelSmall!.copyWith(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: Colors.grey)),
        const SizedBox(width: 5),
        ...LoopControls.steps.map((s) {
          final isSelected = selected == s;
          return Padding(
            padding: const EdgeInsets.only(left: 3),
            child: GestureDetector(
              onTap: () => onChanged(s),
              child: Container(
                height: 22,
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                decoration: BoxDecoration(
                  color:
                      isSelected ? Colors.grey.shade800 : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Text(
                  AbEditControls.stepLabel(s),
                  style: textTheme.labelSmall!.copyWith(
                    fontFamily: 'monospace',
                    color: isSelected
                        ? Colors.grey.shade300
                        : Colors.grey.shade600,
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}
