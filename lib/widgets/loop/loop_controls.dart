import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';

/// エディタ用 AB 微調整パネル（コンパクト版）
class LoopControls extends ConsumerWidget {
  const LoopControls({super.key});

  static const _steps = [0.001, 0.01, 0.1, 1.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loop = ref.watch(loopProvider);
    final notifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final theme = Theme.of(context);

    final stepLabel = loop.adjustStep < 1
        ? '${loop.adjustStep}s'
        : '${loop.adjustStep.toInt()}s';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: AB設定 + Loop toggle + Reset + Step selector
            Row(
              children: [
                const Text('AB設定',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey)),
                const SizedBox(width: 6),
                // Loop toggle
                SizedBox(
                  height: 24,
                  child: FilledButton(
                    onPressed:
                        hasSource ? () => notifier.toggleEnabled() : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: loop.enabled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceContainerHighest,
                      foregroundColor:
                          loop.enabled ? Colors.black : Colors.grey,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                    ),
                    child: Text(loop.enabled ? 'Loop ON' : 'Loop',
                        style: const TextStyle(fontSize: 10)),
                  ),
                ),
                const SizedBox(width: 4),
                // Reset button
                SizedBox(
                  height: 24,
                  width: 24,
                  child: IconButton(
                    icon: const Icon(Icons.restart_alt, size: 16),
                    onPressed: hasSource ? () => notifier.reset() : null,
                    tooltip: 'ABクリア',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const Spacer(),
                const Text('Step ',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                PopupMenuButton<double>(
                  initialValue: loop.adjustStep,
                  onSelected: (v) => notifier.setStep(v),
                  padding: EdgeInsets.zero,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade700),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(stepLabel,
                            style: const TextStyle(fontSize: 12)),
                        const Icon(Icons.arrow_drop_down, size: 16),
                      ],
                    ),
                  ),
                  itemBuilder: (_) => _steps
                      .map((s) => PopupMenuItem(
                            value: s,
                            height: 36,
                            child: Text(
                              s < 1 ? '${s}s' : '${s.toInt()}s',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Point A row: [A button] time [- step] [+ step]
            _PointRow(
              label: 'A',
              color: AppTheme.pointAColor,
              time: loop.pointA,
              stepLabel: stepLabel,
              onSet: hasSource
                  ? () => notifier.setPointAToCurrentPosition()
                  : null,
              onMinus: () => notifier.adjustPointA(-1),
              onPlus: () => notifier.adjustPointA(1),
            ),
            const SizedBox(height: 6),

            // Point B row: [B button] time [- step] [+ step]
            _PointRow(
              label: 'B',
              color: AppTheme.pointBColor,
              time: loop.pointB,
              stepLabel: stepLabel,
              onSet: hasSource
                  ? () => notifier.setPointBToCurrentPosition()
                  : null,
              onMinus: () => notifier.adjustPointB(-1),
              onPlus: () => notifier.adjustPointB(1),
            ),
          ],
        ),
      ),
    );
  }
}

class _PointRow extends StatelessWidget {
  final String label;
  final Color color;
  final Duration time;
  final String stepLabel;
  final VoidCallback? onSet;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _PointRow({
    required this.label,
    required this.color,
    required this.time,
    required this.stepLabel,
    this.onSet,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // A/B set button (tap to set to current position)
        SizedBox(
          width: 34,
          height: 30,
          child: OutlinedButton(
            onPressed: onSet,
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              side: BorderSide(color: color),
              foregroundColor: color,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            child: Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
        const SizedBox(width: 8),
        // Time display
        Text(
          TimeUtils.format(time),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const Spacer(),
        // - step
        SizedBox(
          height: 28,
          child: OutlinedButton(
            onPressed: onMinus,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              side: BorderSide(color: Colors.grey.shade700),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('-$stepLabel', style: const TextStyle(fontSize: 11)),
          ),
        ),
        const SizedBox(width: 4),
        // + step
        SizedBox(
          height: 28,
          child: OutlinedButton(
            onPressed: onPlus,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              side: BorderSide(color: Colors.grey.shade700),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('+$stepLabel', style: const TextStyle(fontSize: 11)),
          ),
        ),
      ],
    );
  }
}
