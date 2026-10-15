import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../glass_panel.dart';
import '../player/player_shell.dart';

/// 横画面で AB 編集ブロック（[AbEditControls] など）を動画の上に重ねるガラス板。
///
/// 縦画面ではコントローラーの中（PlayerGlassBar の extra）に出すが、横画面は
/// コントローラーが脇に入って高さが足りないので、区間パネルと同じ場所に出す。
/// 見出しは区間パネルと同じ余白。中身は収まらなければスクロール
class AbEditPanel extends StatelessWidget {
  const AbEditPanel({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
  });

  final String title;

  /// 見出しの右に薄く出す補足（区間名など）
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(
          PlayerShell.margin, 0, PlayerShell.margin, AppSpacing.lg),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      blur: false,
      scrim: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm),
            child: Row(
              children: [
                Text(title, style: textTheme.titleSmall),
                if (subtitle != null) ...[
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(subtitle!,
                        style: textTheme.labelSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.lg),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
