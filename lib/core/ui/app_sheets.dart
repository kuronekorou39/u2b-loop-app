import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'anchored_menu.dart';

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

  /// これより低い画面（横向きの電話）は「低い画面」。下から出るシートは高さが足りず
  /// 2〜3 行しか見えない（ミニプレイヤーが出ていればさらに狭い）ので、真ん中のダイアログで出す
  static const shortScreenHeight = 500.0;

  /// 下のシートの幅の上限（Material 3 の既定と同じ。タブレットで横いっぱいに広がらない）
  static const sheetMaxWidth = 640.0;

  /// 低い画面で代わりに出すダイアログの幅の上限
  static const dialogMaxWidth = 560.0;

  static bool isShortScreen(BuildContext context) =>
      MediaQuery.sizeOf(context).height < shortScreenHeight;

  /// 下から出るシート。中身は [builder]（上の空きが残るよう高さは画面の 85% まで。
  /// 下のインセットとミニプレイヤーの分は中身が SafeArea か viewPadding で避ける）。
  /// 低い画面では真ん中のダイアログで出す（その中では padding / viewPadding は 0 なので、
  /// 中身はそのまま使える）
  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool showDragHandle = true,
  }) {
    if (isShortScreen(context)) {
      return showDialog<T>(
        context: context,
        builder: (_) => SheetDialog(child: Builder(builder: builder)),
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: showDragHandle,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: sheetMaxWidth,
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      builder: builder,
    );
  }

  /// ボタンの集まり（その他メニュー・DJ ミックス）。向きに関係なく真ん中のダイアログで出す。
  /// 中身は [show] の低い画面のときと同じ（padding / viewPadding は 0）
  static Future<T?> popup<T>(
    BuildContext context, {
    required WidgetBuilder builder,
  }) {
    return showDialog<T>(
      context: context,
      builder: (_) => SheetDialog(child: Builder(builder: builder)),
    );
  }

  /// 見出し（[title] / [subtitle]）と行の並びを出す。[note] は末尾の補足文。
  ///
  /// 一覧の行の ⋮ から開くときは [anchor] にその行の context を渡す。行のすぐ上か下に
  /// 小さなメニューで出し、行は明るいまま残す（見れば対象が分かるので見出しは出さない）。
  /// 行に紐づかないもの・項目が多いものは [anchor] なしで下のシート
  static Future<void> actions(
    BuildContext context, {
    required List<SheetAction> actions,
    BuildContext? anchor,
    String? title,
    String? subtitle,
    String? note,
  }) {
    final navigator = Navigator.of(context);
    final box = anchor != null && anchor.mounted
        ? anchor.findRenderObject() as RenderBox?
        : null;
    if (box != null && box.attached && box.hasSize) {
      final origin = box.localToGlobal(Offset.zero,
          ancestor: navigator.context.findRenderObject());
      return navigator.push<void>(AnchoredMenuRoute<void>(
        anchorRect: origin & box.size,
        builder: (ctx) =>
            _ActionSheet(note: note, actions: actions, popover: true),
      ));
    }
    return show<void>(
      context,
      builder: (ctx) => _ActionSheet(
        title: title,
        subtitle: subtitle,
        note: note,
        actions: actions,
      ),
    );
  }
}

/// 低い画面でシートの中身を入れるダイアログ。シートの中身は下のインセットや
/// ミニプレイヤーの分を SafeArea / viewPadding で避けるが、ダイアログは画面の
/// 安全な範囲に置かれるので、中では両方とも 0 にして無駄な余白を作らない
class SheetDialog extends StatelessWidget {
  const SheetDialog({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xxl, vertical: AppSpacing.xl),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSheets.dialogMaxWidth),
          child: Builder(
            builder: (ctx) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(
                  padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.lg),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
}

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.actions,
    this.title,
    this.subtitle,
    this.note,
    this.popover = false,
  });

  final List<SheetAction> actions;
  final String? title;
  final String? subtitle;
  final String? note;

  /// 行の脇に出す小さなメニュー（下のインセットを避けない・行を詰める）
  final bool popover;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return SingleChildScrollView(
      padding: popover
          ? const EdgeInsets.symmetric(vertical: AppSpacing.xs)
          : EdgeInsets.only(bottom: bottom + AppSpacing.md),
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
                visualDensity: popover ? VisualDensity.compact : null,
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
              padding: EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.md,
                  AppSpacing.xl, popover ? AppSpacing.md : 0),
              child: Text(note!,
                  style: textTheme.bodySmall?.copyWith(color: dim)),
            ),
        ],
      ),
    );
  }
}
