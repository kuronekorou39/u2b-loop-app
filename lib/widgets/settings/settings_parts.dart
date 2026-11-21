import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../glass_scaffold.dart';
import '../glass_surface.dart';

/// 設定の 1 ページ: ガラスの土台 + 縦に並ぶ群。
/// 本文の上端は AppBar の下端（extendBodyBehindAppBar）から始める。
/// [wideColumns] を渡すと、横画面ではその列に分けて群を並べ、スクロールせずに収める
/// （縦に 1 列のままだと行が画面の端まで伸び、データのページは下が切れてスクロールしていた）
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.wideColumns,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;

  /// 横画面の並べ方（列ごとの群。左の列から）。[children] と同じ群を分けて渡す。
  /// null なら横画面でも縦と同じ 1 列
  final List<List<Widget>>? wideColumns;

  /// 列に分けて並べる幅（これより狭いか縦長なら 1 列）
  static const wideMinWidth = 600.0;

  /// 横画面の中身の幅の上限（広い画面で間延びしないように）
  static const maxWideWidth = 960.0;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return GlassScaffold(
      title: Text(title, style: textTheme.titleMedium),
      actions: actions,
      bodyBuilder: (context) {
          final padding = MediaQuery.paddingOf(context);
          final viewPadding = MediaQuery.viewPaddingOf(context);
          final columns = wideColumns;
          return LayoutBuilder(builder: (context, c) {
            final wide = columns != null &&
                c.maxWidth >= wideMinWidth &&
                c.maxWidth > c.maxHeight;
            if (!wide) {
              return ListView(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg + viewPadding.left,
                  padding.top + AppSpacing.md,
                  AppSpacing.lg + viewPadding.right,
                  padding.bottom + AppSpacing.xxl,
                ),
                children: children,
              );
            }
            // 横: 群を列に並べて収める（収まらないほど低い画面でだけスクロールする）
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg + viewPadding.left,
                padding.top + AppSpacing.md,
                AppSpacing.lg + viewPadding.right,
                padding.bottom + AppSpacing.md,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: maxWideWidth),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < columns.length; i++) ...[
                        if (i > 0) const SizedBox(width: AppSpacing.lg),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: columns[i],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          });
      },
    );
  }
}

/// 行をまとめた群（1 枚のガラス面。行の間に薄い線）
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.title});

  final List<Widget> children;

  /// 群の上に出す小さな見出し。null なら無し
  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = theme.colorScheme.onSurface.withValues(alpha: 0.06);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Text(
                title!,
                style: theme.textTheme.labelMedium!.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          GlassSurface(
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: 54, color: line),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 設定の 1 行: アイコン / タイトル / 説明（現在値）/ 右端（既定は ›）
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.danger = false,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 右端。null なら（タップできる行には）›
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  /// 取り返しのつかない操作（赤）
  final bool danger;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final fg = danger ? Colors.red : theme.colorScheme.onSurface;
    final trailingWidget = trailing ??
        (onTap != null && showChevron
            ? Icon(Icons.chevron_right,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5))
            : null);
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
          child: Row(
            children: [
              Icon(icon, size: AppIconSizes.ml, color: fg.withValues(alpha: 0.85)),
              const SizedBox(width: AppSpacing.xl),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.bodyLarge!.copyWith(color: fg)),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: textTheme.labelSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (trailingWidget != null) ...[
                const SizedBox(width: AppSpacing.md),
                trailingWidget,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// スイッチの行。行全体のタップでも切り替わる
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;

  /// null なら無効
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      enabled: onChanged != null,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}
