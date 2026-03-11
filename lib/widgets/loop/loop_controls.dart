import 'package:flutter/material.dart';
import '../../core/utils/time_utils.dart';

/// AB設定の共通ウィジェット（静的メソッドで提供）
class LoopControls {
  LoopControls._();

  static const steps = [0.001, 0.01, 0.1, 1.0];

  /// A/B ポイント行
  static Widget buildPointRow({
    required String label,
    required Color color,
    required Duration time,
    required String stepLabel,
    VoidCallback? onSet,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    return Row(
      children: [
        // A/B set button
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
