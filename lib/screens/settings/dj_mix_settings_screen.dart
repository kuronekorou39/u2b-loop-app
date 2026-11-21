import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/glass_scaffold.dart';
import '../../widgets/player/dj_mix_controls.dart';

/// 設定「DJ ミックス」。中身は再生画面の DJ ミックスのポップアップと同じ [DjMixControls]
/// （縦でも横でもスクロールせずに全部収める）。
/// 音量の正規化は 1 曲ずつ聴くときにも効くので「表示・再生」に置く（ここは群を増やすと
/// 小さい画面で収まらない）
class DjMixSettingsScreen extends StatelessWidget {
  const DjMixSettingsScreen({super.key});

  /// 中身の幅の上限（広い画面で間延びしないように）
  static const _maxContentWidth = 960.0;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GlassScaffold(
      title: Text('DJ ミックス', style: textTheme.titleMedium),
      bodyBuilder: (context) {
        final padding = MediaQuery.paddingOf(context);
        final viewPadding = MediaQuery.viewPaddingOf(context);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.xl + viewPadding.left,
            padding.top + AppSpacing.md,
            AppSpacing.xl + viewPadding.right,
            padding.bottom + AppSpacing.xl,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: const DjMixControls(),
            ),
          ),
        );
      },
    );
  }
}
