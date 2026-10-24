import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_provider.dart';

/// 効果音のタイミングの補正を 10ms 刻みで動かす「−」「+20ms」「+」。
/// 設定の DJ ミックスのページと再生画面のシートで共用（値は [sfxOffsetMsProvider]）
class SfxOffsetStepper extends ConsumerWidget {
  const SfxOffsetStepper({super.key, this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms = ref.watch(sfxOffsetMsProvider);
    final notifier = ref.read(sfxOffsetMsProvider.notifier);
    final style = Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove),
          tooltip: '${SfxOffsetNotifier.step}ms 早く',
          visualDensity: VisualDensity.compact,
          onPressed: enabled && ms > -SfxOffsetNotifier.maxAbsMs
              ? () => notifier.nudge(-SfxOffsetNotifier.step)
              : null,
        ),
        // 幅を固定して「−」「+」が動かないように
        SizedBox(
          width: 56,
          child: Text(
            SfxOffsetNotifier.label(ms),
            textAlign: TextAlign.center,
            style: style,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: '${SfxOffsetNotifier.step}ms 遅く',
          visualDensity: VisualDensity.compact,
          onPressed: enabled && ms < SfxOffsetNotifier.maxAbsMs
              ? () => notifier.nudge(SfxOffsetNotifier.step)
              : null,
        ),
      ],
    );
  }
}
