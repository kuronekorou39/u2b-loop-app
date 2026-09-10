import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';

/// AB区間リストの1行。名前と「A - B (長さ)」を表示し、選択中は強調する。
class RegionTile extends StatelessWidget {
  const RegionTile({
    super.key,
    required this.name,
    required this.isActive,
    required this.onTap,
    this.pointAMs,
    this.pointBMs,
    this.onLongPress,
  });

  final String name;
  final bool isActive;
  final VoidCallback onTap;
  final int? pointAMs;
  final int? pointBMs;
  final VoidCallback? onLongPress;

  bool get _hasAnyPoint => pointAMs != null || pointBMs != null;

  String get _timeText {
    if (!_hasAnyPoint) return '未設定';
    final a = TimeUtils.formatShortNullable(
        pointAMs != null ? Duration(milliseconds: pointAMs!) : null);
    final b = TimeUtils.formatShortNullable(
        pointBMs != null ? Duration(milliseconds: pointBMs!) : null);
    if (pointAMs == null || pointBMs == null) return '$a - $b';
    final durationSec = (pointBMs! - pointAMs!).abs() / 1000;
    return '$a - $b (${durationSec.toStringAsFixed(1)}s)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: AppRadius.borderSm,
      child: Container(
        padding:
            const EdgeInsets.symmetric(vertical: 5, horizontal: AppSpacing.xs),
        decoration: BoxDecoration(
          color:
              isActive ? theme.colorScheme.primary.withValues(alpha: 0.15) : null,
          borderRadius: AppRadius.borderSm,
          border: Border.all(
            color: isActive
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: textTheme.labelMedium!.copyWith(
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                color: isActive ? theme.colorScheme.primary : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              _timeText,
              style: textTheme.labelSmall!.copyWith(
                fontSize: 10,
                color: _hasAnyPoint ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ループのGap（B点到達後にA点へ戻るまでの待ち時間）スライダー。0〜10秒。
class LoopGapSlider extends StatelessWidget {
  const LoopGapSlider({
    super.key,
    required this.gapSeconds,
    required this.onChanged,
  });

  final double gapSeconds;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Text('Gap:', style: textTheme.labelSmall),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 2,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: gapSeconds,
                min: 0,
                max: 10,
                divisions: 20,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text('${gapSeconds.toStringAsFixed(1)}s',
                style: textTheme.labelSmall),
          ),
        ],
      ),
    );
  }
}

/// A点/B点の時刻表示。設定済みならタップでその位置へシークできる。
class LoopPointDisplay extends StatelessWidget {
  const LoopPointDisplay({
    super.key,
    required this.label,
    required this.color,
    required this.time,
    required this.onSeek,
  });

  final String label;
  final Color color;
  final Duration? time;

  /// 時刻タップ時のシーク処理（[time] が null のときは呼ばれない）
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final t = time;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: AppRadius.borderSm,
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: textTheme.bodyMedium!
                  .copyWith(fontWeight: FontWeight.bold, color: color)),
        ),
        const SizedBox(width: AppSpacing.md),
        GestureDetector(
          onTap: t != null ? () => onSeek(t) : null,
          child: Text(
            TimeUtils.formatNullable(t),
            style: textTheme.bodyMedium!.copyWith(
              fontFamily: 'monospace',
              decoration: t != null ? TextDecoration.underline : null,
              decorationColor: color.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }
}
