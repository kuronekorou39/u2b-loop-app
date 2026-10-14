import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 下から出るメニュー（アクションシート）の 1 行。
///
/// [SheetAction.heading] は区切りの見出し（タップできない）。
/// [selected] は「今これが選ばれている」印（言語の選択など）。
class SheetAction {
  const SheetAction({
    required this.label,
    this.icon,
    this.subtitle,
    this.onTap,
    this.destructive = false,
    this.enabled = true,
    this.selected = false,
  }) : isHeading = false;

  const SheetAction.heading(this.label)
      : icon = null,
        subtitle = null,
        onTap = null,
        destructive = false,
        enabled = true,
        selected = false,
        isHeading = true;

  final String label;
  final IconData? icon;
  final String? subtitle;

  /// シートが閉じてから呼ばれる
  final VoidCallback? onTap;

  /// 削除など戻しにくい操作（赤で出す）
  final bool destructive;
  final bool enabled;
  final bool selected;
  final bool isHeading;
}

/// アプリ共通のアクションシート。
///
/// 以前は showModalBottomSheet に Column + ListTile を 12 か所以上で直書きしており、
/// 件数が多いとスクロールできずにはみ出す・SafeArea の有無が違う・削除の赤が
/// Colors.red と redAccent で違う、といったばらつきがあった。
class AppSheets {
  AppSheets._();

  /// 見出し（[title] / [subtitle]）と行の並びを出す。[note] は末尾の補足文
  static Future<void> actions(
    BuildContext context, {
    required List<SheetAction> actions,
    String? title,
    String? subtitle,
    String? note,
  }) {
    return showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      builder: (ctx) => _ActionSheet(
        title: title,
        subtitle: subtitle,
        note: note,
        actions: actions,
      ),
    );
  }
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.actions,
    this.title,
    this.subtitle,
    this.note,
  });

  final List<SheetAction> actions;
  final String? title;
  final String? subtitle;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: bottom + AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(title!,
                        style: textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  if (subtitle != null)
                    Text(subtitle!, style: textTheme.bodySmall),
                ],
              ),
            ),
          if (title != null || subtitle != null) const Divider(height: 1),
          for (final a in actions)
            if (a.isHeading)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xs),
                child: Text(a.label,
                    style: textTheme.labelSmall!.copyWith(
                        color: AppTheme.accentGreen,
                        fontWeight: FontWeight.bold)),
              )
            else
              ListTile(
                enabled: a.enabled,
                leading: a.icon == null
                    ? null
                    : Icon(a.icon,
                        color: !a.enabled
                            ? dim
                            : a.destructive
                                ? AppTheme.accentRed
                                : a.selected
                                    ? AppTheme.accentGreen
                                    : null),
                title: Text(
                  a.label,
                  style: textTheme.bodyLarge?.copyWith(
                    color: a.destructive && a.enabled
                        ? AppTheme.accentRed
                        : null,
                    fontWeight: a.selected ? FontWeight.bold : null,
                  ),
                ),
                subtitle: a.subtitle == null
                    ? null
                    : Text(a.subtitle!, style: textTheme.bodySmall),
                trailing: a.selected
                    ? const Icon(Icons.check,
                        color: AppTheme.accentGreen, size: AppIconSizes.sm)
                    : null,
                onTap: a.onTap == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        a.onTap!();
                      },
              ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.md, AppSpacing.xl, 0),
              child: Text(note!,
                  style: textTheme.bodySmall?.copyWith(color: dim)),
            ),
        ],
      ),
    );
  }
}
