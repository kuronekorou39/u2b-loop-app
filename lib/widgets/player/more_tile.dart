import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sheets.dart';

/// 「その他」メニューの四角いボタン（アイコン + 一言 + 任意の今の値）。
///
/// 以前は ListTile の一覧で、横向きの電話では 2〜3 行しか見えなかった。
/// タイルなら縦でも横でも同じ組み方で、幅に合わせて列数が変わるだけ。
/// オンオフのもの（[active]）は緑に光らせ、押しても場所は動かない。
class MoreTile extends StatelessWidget {
  const MoreTile({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
    this.active = false,
    this.enabled = true,
  });

  final IconData icon;
  final String label;

  /// 今の値（速度の 1.0x、出力の「スピーカー」など）。ラベルの下に小さく
  final String? value;

  /// null なら情報だけ（押せない）
  final VoidCallback? onTap;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final fg = !enabled
        ? AppTheme.muted(context)
        : active
            ? AppTheme.accentGreen
            : onSurface;
    final fill = active && enabled
        ? AppTheme.accentGreen.withValues(alpha: 0.16)
        : onSurface.withValues(alpha: 0.08);
    final radius = BorderRadius.circular(AppRadius.xl);
    return Material(
      color: fill,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: AppIconSizes.xl, color: fg),
              const SizedBox(height: AppSpacing.sm),
              Text(
                label,
                style: theme.textTheme.labelMedium!.copyWith(
                  color: fg,
                  fontWeight: active ? FontWeight.bold : null,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (value != null)
                Text(
                  value!,
                  style: theme.textTheme.labelSmall!.copyWith(
                    color: enabled ? AppTheme.muted(context, alpha: 0.8) : fg,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// タイルを正方形で敷き詰める。幅から列数を決める（縦の電話は 3 列、
/// 低い画面〔横向きの電話〕は小さめにして 1 行に 6 つまで）
class MoreTileGrid extends StatelessWidget {
  const MoreTileGrid({super.key, required this.tiles});

  final List<Widget> tiles;

  /// タイル 1 つの幅の上限。これより狭くなるまで列を増やさない
  static const maxExtent = 130.0;

  /// 低い画面での上限（高さが無いので 1 行に収まるよう小さめ）
  static const maxExtentShort = 96.0;

  @override
  Widget build(BuildContext context) {
    final short = AppSheets.isShortScreen(context);
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: short ? maxExtentShort : maxExtent,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
      ),
      children: tiles,
    );
  }
}
