import 'package:flutter/material.dart';

/// ガラス板の上に置く、ぼかし無しの薄い面（一覧の行のまとまり・カード・設定の群）。
///
/// 一覧で大量に使うので BackdropFilter は使わず、白（ライトテーマでは黒）を薄く重ねるだけ。
/// 枠線はなし。浮いている板（ミニプレイヤー・タブ・シート）は GlassPanel を使う。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 16,
    this.margin,
    this.padding,
    this.onTap,
    this.onLongPress,
    this.tint,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 面に混ぜる色（選択中の緑・タグの色など）。null なら白/黒だけ。
  /// BoxDecoration は gradient があると color を無視するので、gradient の各色に混ぜる
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? Colors.white : Colors.black;
    final borderRadius = BorderRadius.circular(radius);
    final tint = this.tint;
    Color layer(double alpha) {
      final c = base.withValues(alpha: alpha);
      return tint == null ? c : Color.alphaBlend(c, tint);
    }

    final decoration = BoxDecoration(
      borderRadius: borderRadius,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [layer(dark ? 0.10 : 0.06), layer(dark ? 0.04 : 0.03)],
      ),
    );

    Widget body = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    if (onTap != null || onLongPress != null) {
      body = InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: borderRadius,
        child: body,
      );
    }
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Ink(decoration: decoration, child: body),
      ),
    );
  }
}
