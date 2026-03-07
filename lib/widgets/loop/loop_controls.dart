import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';

class LoopControls extends ConsumerWidget {
  const LoopControls({super.key});

  static const _steps = [0.001, 0.01, 0.1, 1.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loop = ref.watch(loopProvider);
    final notifier = ref.read(loopProvider.notifier);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Loop toggle + set buttons + reset
            Row(
              children: [
                _ActionButton(
                  label: 'A',
                  color: AppTheme.pointAColor,
                  onPressed: hasSource
                      ? () => notifier.setPointAToCurrentPosition()
                      : null,
                ),
                const SizedBox(width: 8),
                _ActionButton(
                  label: 'B',
                  color: AppTheme.pointBColor,
                  onPressed: hasSource
                      ? () => notifier.setPointBToCurrentPosition()
                      : null,
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.restart_alt, size: 20),
                  onPressed: hasSource ? () => notifier.reset() : null,
                  tooltip: 'リセット',
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: hasSource ? () => notifier.toggleEnabled() : null,
                  icon: Icon(
                    loop.enabled ? Icons.repeat_on : Icons.repeat,
                    size: 18,
                  ),
                  label: Text(loop.enabled ? 'ON' : 'OFF'),
                  style: FilledButton.styleFrom(
                    backgroundColor: loop.enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    foregroundColor: loop.enabled ? Colors.black : Colors.grey,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 36),
                  ),
                ),
              ],
            ),

            if (loop.hasPoints) ...[
              const SizedBox(height: 12),

              // Point A adjustment
              _PointRow(
                label: 'A',
                color: AppTheme.pointAColor,
                time: loop.pointA,
                onMinus: () => notifier.adjustPointA(-1),
                onPlus: () => notifier.adjustPointA(1),
              ),
              const SizedBox(height: 6),

              // Point B adjustment
              _PointRow(
                label: 'B',
                color: AppTheme.pointBColor,
                time: loop.pointB,
                onMinus: () => notifier.adjustPointB(-1),
                onPlus: () => notifier.adjustPointB(1),
              ),
              const SizedBox(height: 10),

              // Step selector
              Row(
                children: [
                  const Text('Step:', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
                  ..._steps.map(
                    (s) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(
                          s < 1 ? '${s}s' : '${s.toInt()}s',
                          style: const TextStyle(fontSize: 11),
                        ),
                        selected: loop.adjustStep == s,
                        onSelected: (_) => notifier.setStep(s),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Gap control
              Row(
                children: [
                  const Text('Gap:', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: loop.gapSeconds,
                      min: 0,
                      max: 10,
                      divisions: 20,
                      label: '${loop.gapSeconds.toStringAsFixed(1)}s',
                      onChanged: (v) => notifier.setGap(v),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${loop.gapSeconds.toStringAsFixed(1)}s',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.label,
    required this.color,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 36,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          side: BorderSide(color: color),
          foregroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}

class _PointRow extends StatelessWidget {
  final String label;
  final Color color;
  final Duration time;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _PointRow({
    required this.label,
    required this.color,
    required this.time,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 20,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          TimeUtils.format(time),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 14,
          ),
        ),
        const Spacer(),
        SizedBox(
          width: 36,
          height: 32,
          child: IconButton(
            icon: const Icon(Icons.remove, size: 16),
            onPressed: onMinus,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              side: BorderSide(color: Colors.grey.shade700),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 36,
          height: 32,
          child: IconButton(
            icon: const Icon(Icons.add, size: 16),
            onPressed: onPlus,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              side: BorderSide(color: Colors.grey.shade700),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
