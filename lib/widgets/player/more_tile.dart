import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sheets.dart';

/// 四角い大きなボタン（大きなアイコン + 一言 + 任意の今の値。中身は真ん中に寄せる）。
/// 再生画面の「その他」・DJ ミックス・設定のトップで使う。
///
/// 見た目の決まり:
/// - タイルの面はどれも同じ色（オンオフで面を塗り分けない。塗ると「どれが何の色か
///   分からない」と言われた）。右上の矢印（› ▾）も付けない
/// - アイコンはアクセントの緑。オンオフが切り替わるもの（[active] を渡す）は、
///   ラベルの下に「オン」「オフ」と書き、オフの間だけアイコンが灰色になる
/// - 今の値があるもの（速度の 1.0x など）はラベルの下に小さく書く
/// アイコンと文字はタイルの大きさに合わせて大きくなる。押しても場所は動かない。
class MoreTile extends StatelessWidget {
  const MoreTile({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
    this.active,
    this.enabled = true,
    this.dense = false,
  });

  final IconData icon;
  final String label;

  /// 今の値（速度の 1.0x、出力の「スピーカー」など）。ラベルの下に小さく。
  /// [active] を渡して値が無ければ「オン」「オフ」
  final String? value;

  /// null なら情報だけ（押せない）
  final VoidCallback? onTap;

  /// オンオフが切り替わるものだけに渡す（null = オンオフではない）
  final bool? active;
  final bool enabled;

  /// 小さめ（DJ ミックスのように数が多いとき）。文字を一回り小さく、
  /// 値が無ければラベルは 2 行まで
  final bool dense;

  /// アイコンの大きさ（タイルの短い辺に対する割合）と、その下限・上限
  static const iconScale = 0.36;
  static const iconMin = 20.0;
  static const iconMax = 72.0;

  /// この大きさ以上のタイル（設定のトップ）は文字も大きく
  static const largeSide = 140.0;

  /// アイコン以外（余白・ラベル・値）に取っておく高さ。小さいタイルで溢れないように
  static const _textReserve = 62.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final muted = AppTheme.muted(context);
    final off = active == false;
    final iconColor = enabled
        ? (off ? muted : AppTheme.accentGreen)
        : (off ? muted.withValues(alpha: 0.4) : AppTheme.accentGreen.withValues(alpha: 0.4));
    final textColor = enabled ? onSurface : muted;
    final shown = value ?? (active == null ? null : (active! ? 'オン' : 'オフ'));
    final radius = BorderRadius.circular(dense ? AppRadius.lg : AppRadius.xl);
    return Material(
      color: onSurface.withValues(alpha: enabled ? 0.08 : 0.04),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: radius,
        child: LayoutBuilder(builder: (context, c) {
          final side = c.biggest.shortestSide;
          final large = side >= largeSide;
          final iconSize = (side * iconScale)
              .clamp(iconMin, iconMax)
              .clamp(iconMin, (side - _textReserve).clamp(iconMin, iconMax))
              .toDouble();
          final labelStyle = (dense
                  ? theme.textTheme.labelSmall
                  : large
                      ? theme.textTheme.bodyLarge
                      : theme.textTheme.labelMedium)!
              .copyWith(color: textColor, fontWeight: FontWeight.w600);
          final valueStyle = (large
                  ? theme.textTheme.labelMedium
                  : theme.textTheme.labelSmall)!
              .copyWith(color: AppTheme.muted(context, alpha: enabled ? 0.8 : 0.5));
          return Padding(
            // 小さめは 7 文字のラベル（ベーススワップ）が 1 行に入るよう横の余白を詰める
            padding: EdgeInsets.all(dense ? AppSpacing.xs : AppSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, size: iconSize, color: iconColor),
                SizedBox(
                    height: dense
                        ? AppSpacing.xs
                        : large
                            ? AppSpacing.md
                            : AppSpacing.sm),
                Text(
                  label,
                  style: labelStyle,
                  textAlign: TextAlign.center,
                  maxLines: dense && shown == null ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (shown != null)
                  Text(
                    shown,
                    style: valueStyle,
                    textAlign: TextAlign.center,
                    // 長い値（フィルタースイープ）は小さめのとき 2 行まで
                    maxLines: dense ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

/// [context] のウィジェットのすぐ下に出すメニューの位置（showMenu の position）。
/// ボタンに被せない（下に入らなければ showMenu が画面内に押し戻す）
RelativeRect anchoredMenuPosition(BuildContext context) {
  final box = context.findRenderObject() as RenderBox;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final rect = Rect.fromPoints(
    box.localToGlobal(Offset.zero, ancestor: overlay),
    box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  final below = Rect.fromLTRB(rect.left, rect.bottom, rect.right, rect.bottom);
  return RelativeRect.fromRect(below, Offset.zero & overlay.size);
}

/// [context] のボタンの下に候補を出して選ばせる。今の値には ✓
/// （showMenu の initialValue は今の値をボタンに重ねる位置にずらすので使わない）
Future<T?> showAnchoredPicker<T>(
  BuildContext context, {
  required List<T> values,
  required T selected,
  required String Function(T) labelOf,
}) =>
    showMenu<T>(
      context: context,
      position: anchoredMenuPosition(context),
      items: [
        for (final v in values)
          PopupMenuItem(
            value: v,
            child: Row(
              children: [
                SizedBox(
                  width: AppIconSizes.lg,
                  child: v == selected
                      ? const Icon(Icons.check,
                          size: AppIconSizes.md, color: AppTheme.accentGreen)
                      : null,
                ),
                const SizedBox(width: AppSpacing.md),
                Text(labelOf(v),
                    style: v == selected
                        ? const TextStyle(fontWeight: FontWeight.bold)
                        : null),
              ],
            ),
          ),
      ],
    );

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
    final picked = await showAnchoredPicker<T>(context,
        values: values, selected: selected, labelOf: labelOf);
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) => Builder(
        builder: (ctx) => MoreTile(
          icon: icon,
          label: label,
          value: labelOf(selected),
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
