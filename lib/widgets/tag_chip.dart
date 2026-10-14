import 'package:flutter/material.dart';

import '../models/tag.dart';

/// タグのチップ（共通）。タグ色を薄く敷いた丸いピルに、タグ色の明るい版で名前。
/// 一覧・詳細・プレイリストで同じ見た目にする（以前は画面ごとに濃さが違った）
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.tag,
    this.small = false,
    this.onTap,
    this.onDeleted,
    this.excluded = false,
  });

  final Tag tag;

  /// グリッドのカードなど狭い所向け
  final bool small;
  final VoidCallback? onTap;

  /// 右に × を出す（絞り込みの解除など）
  final VoidCallback? onDeleted;

  /// 除外フィルタ（赤い取り消し線）
  final bool excluded;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hsl = HSLColor.fromColor(tag.color);
    final fg = excluded
        ? Colors.red.shade300
        : hsl
            .withLightness(dark ? 0.78 : 0.3)
            .withSaturation((hsl.saturation * 0.9).clamp(0.3, 1.0))
            .toColor();
    final bg = (excluded ? Colors.red : tag.color).withValues(alpha: dark ? 0.22 : 0.16);
    final textStyle = Theme.of(context).textTheme.labelSmall!.copyWith(
          fontSize: small ? 10 : 11,
          color: fg,
          fontWeight: FontWeight.w500,
          decoration: excluded ? TextDecoration.lineThrough : null,
          decorationColor: fg,
        );
    final chip = Container(
      padding: EdgeInsets.symmetric(
          horizontal: small ? 7 : 9, vertical: small ? 2 : 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tag.name, style: textStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (onDeleted != null) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onDeleted,
              child: Icon(Icons.close, size: small ? 11 : 13, color: fg),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: chip,
    );
  }
}
