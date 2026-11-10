import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sheets.dart';

/// 「その他」メニューの四角いボタン（アイコン + 一言 + 任意の今の値）。
///
/// 見た目の決まり（混ぜると「光る理由が分からない」と言われた）:
/// - 押すとオンオフが切り替わるもの → オンのとき緑に光る（[active]）
/// - 別の画面やシートを開くもの → 右上に「›」（[corner] に [Icons.chevron_right]）、光らない
/// - 候補から選ぶもの → 右上に「▾」と今の値（[PickerTile]）、光らない
/// 以前は ListTile の一覧で、横向きの電話では 2〜3 行しか見えなかった。
/// タイルなら縦でも横でも同じ組み方で、幅に合わせて列数が変わるだけ。
/// 押しても場所は動かない。
class MoreTile extends StatelessWidget {
  const MoreTile({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
    this.active = false,
    this.enabled = true,
    this.corner,
    this.dense = false,
  });

  final IconData icon;
  final String label;

  /// 今の値（速度の 1.0x、出力の「スピーカー」など）。ラベルの下に小さく
  final String? value;

  /// null なら情報だけ（押せない）
  final VoidCallback? onTap;

  /// オン（緑に光る）。オンオフが切り替わるものだけに使う
  final bool active;
  final bool enabled;

  /// 右上の小さな印（開く「›」・選ぶ「▾」）
  final IconData? corner;

  /// 小さめ（DJ ミックスのように数が多いとき）。アイコンと文字を一回り小さく、
  /// 値が無ければラベルは 2 行まで
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    const green = AppTheme.accentGreen;
    // 押せないときも、オンかどうかは薄く残す
    final fg = enabled
        ? (active ? green : onSurface)
        : (active ? green.withValues(alpha: 0.45) : AppTheme.muted(context));
    final fill = active
        ? green.withValues(alpha: enabled ? 0.16 : 0.07)
        : onSurface.withValues(alpha: enabled ? 0.08 : 0.04);
    final radius = BorderRadius.circular(dense ? AppRadius.lg : AppRadius.xl);
    final labelStyle = (dense ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)!
        .copyWith(color: fg, fontWeight: active ? FontWeight.bold : null);
    return Material(
      color: fill,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: radius,
        child: Stack(
          children: [
            Padding(
              // 小さめは 7 文字のラベル（ベーススワップ）が 1 行に入るよう横の余白を詰める
              padding: EdgeInsets.all(dense ? AppSpacing.xs : AppSpacing.sm),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      size: dense ? AppIconSizes.ml : AppIconSizes.xl, color: fg),
                  SizedBox(height: dense ? AppSpacing.xs : AppSpacing.sm),
                  Text(
                    label,
                    style: labelStyle,
                    textAlign: TextAlign.center,
                    maxLines: dense && value == null ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (value != null)
                    Text(
                      value!,
                      style: theme.textTheme.labelSmall!.copyWith(
                        color: enabled ? AppTheme.muted(context, alpha: 0.8) : fg,
                      ),
                      textAlign: TextAlign.center,
                      // 長い値（フィルタースイープ）は小さめのとき 2 行まで
                      maxLines: dense ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (corner != null)
              Positioned(
                top: AppSpacing.xs,
                right: AppSpacing.xs,
                child: Icon(corner,
                    size: AppIconSizes.s,
                    color: AppTheme.muted(context, alpha: enabled ? 0.7 : 0.4)),
              ),
          ],
        ),
      ),
    );
  }
}

/// 候補から選ぶタイル。今の値を出し、押すとその場に候補のメニュー
/// （候補を並べると見づらいのでプルダウン）
class PickerTile<T> extends StatelessWidget {
  const PickerTile({
    super.key,
    required this.icon,
    required this.label,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onPicked,
    this.enabled = true,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onPicked;
  final bool enabled;
  final bool dense;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final rect = Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final picked = await showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      initialValue: selected,
      items: [
        for (final v in values) PopupMenuItem(value: v, child: Text(labelOf(v))),
      ],
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) => Builder(
        builder: (ctx) => MoreTile(
          icon: icon,
          label: label,
          value: labelOf(selected),
          corner: Icons.arrow_drop_down,
          enabled: enabled,
          dense: dense,
          onTap: () => _open(ctx),
        ),
      );
}

/// タイルを敷き詰める。幅から列数を決める（縦の電話は 3 列、
/// 低い画面〔横向きの電話〕は小さめにして 1 行に 6 つまで）。
/// [dense] は数が多いとき（DJ ミックス）: 一回り小さく、少し横長で、縦 3 列・横 5 列
class MoreTileGrid extends StatelessWidget {
  const MoreTileGrid({super.key, required this.tiles, this.dense = false});

  final List<Widget> tiles;
  final bool dense;

  /// タイル 1 つの幅の上限。これより狭くなるまで列を増やさない
  static const maxExtent = 130.0;

  /// 低い画面での上限（高さが無いので 1 行に収まるよう小さめ）
  static const maxExtentShort = 96.0;

  /// 小さめのときの列の決め方: この幅で 1 列（切り上げ）、ただし 3 列は下回らない。
  /// 縦の電話（ダイアログの中身 300〜370）は 3 列、横向きの電話のダイアログ（528）は 5 列。
  /// 幅の上限で決めると 340 前後の電話で 4 列（83px）になり、7 文字のラベルが入らなかった
  static const denseColumnWidth = 130.0;
  static const denseMinColumns = 3;

  /// 小さめのタイルの横 / 縦
  static const denseAspect = 1.05;

  @override
  Widget build(BuildContext context) {
    final short = AppSheets.isShortScreen(context);
    final gap = dense ? AppSpacing.sm : AppSpacing.md;
    final padding =
        EdgeInsets.symmetric(horizontal: dense ? AppSpacing.lg : AppSpacing.xl);
    if (dense) {
      return LayoutBuilder(builder: (context, c) {
        final width = c.maxWidth - padding.horizontal;
        final columns =
            math.max(denseMinColumns, (width / denseColumnWidth).ceil());
        return GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: denseAspect,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
          ),
          children: tiles,
        );
      });
    }
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: short ? maxExtentShort : maxExtent,
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
      ),
      children: tiles,
    );
  }
}
