import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sheets.dart';
import 'dj_mix_controls.dart';

/// 再生画面から開く「DJ ミックス」のポップアップ。
///
/// 中身は設定の DJ ミックスのページと同じ [DjMixControls]（同じ値を、聴きながらその場で
/// 変える）。変更は次の切り替わりから効く（PlaylistEngine は交差を始めるときに設定を読む）。
/// スクロールせずに収まるよう、横画面ではポップアップを広げてページと同じ左右 2 列にする。
/// 縦は画面の端との間と中の余白を詰めて幅を取る（小さい電話でボタンの名前がくっついた）
class DjMixSheet extends StatelessWidget {
  const DjMixSheet({super.key});

  /// ポップアップの幅の上限（横画面で左右 2 列に並べられる幅）
  static const maxWidth = 880.0;

  static Future<void> show(BuildContext context) {
    return AppSheets.popup<void>(
      context,
      maxWidth: maxWidth,
      sideInset: AppSpacing.lg,
      builder: (_) => const DjMixSheet(),
    );
  }

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.xs,
      AppSpacing.lg,
      AppSpacing.xl,
    ),
    child: DjMixControls(shrinkWrap: true),
  );
}
