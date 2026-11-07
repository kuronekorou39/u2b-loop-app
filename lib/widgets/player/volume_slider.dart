import 'package:flutter/material.dart';

import '../../core/audio/loudness.dart';
import '../../core/theme/app_theme.dart';

/// 音量のスライダー（0〜[Loudness.maxVolume]%）。100% の位置に目印を置き、
/// 100% を超えた分は赤で（上げすぎると音が割れやすい）
class VolumeSlider extends StatelessWidget {
  const VolumeSlider({super.key, required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    const max = Loudness.maxVolume;
    final loud = value > 100;
    return LayoutBuilder(builder: (context, c) {
      // Slider の左右の余白（つまみの半径 + 既定の余白）を除いた所が 0〜max
      const pad = 24.0;
      final x = pad + (c.maxWidth - pad * 2) * (100 / max);
      return Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: x - 1,
            child: Container(
              width: 2,
              height: 14,
              color: AppTheme.muted(context, alpha: 0.5),
            ),
          ),
          Slider(
            value: value.clamp(0, max),
            min: 0,
            max: max,
            activeColor: loud ? AppTheme.accentRed : null,
            onChanged: onChanged,
          ),
        ],
      );
    });
  }
}
