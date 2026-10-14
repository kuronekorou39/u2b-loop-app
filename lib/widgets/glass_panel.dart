import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/glass_provider.dart';

/// ガラス板: 背景をぼかして白を薄く重ねた角丸の面。枠線は付けない。
///
/// 再生画面のコントローラー・トラック一覧・ピルに使う。
/// ぼかし（BackdropFilter）は GPU 負荷があるので、設定で切れる（[glassBlurProvider]）。
/// 切ったときは半透明の板だけになる。
/// ピルのように板の上に重ねる小さな要素は [blur] を false にして、ぼかしを二重にしない。
class GlassPanel extends ConsumerWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 22,
    this.margin,
    this.padding,
    this.fill = 0.07,
    this.blur = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  /// 重ねる白の濃さ（0〜1）
  final double fill;

  /// 背景をぼかすか。false なら半透明の板だけ
  final bool blur;

  static const blurSigma = 24.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blurOn = blur && ref.watch(glassBlurProvider);
    final borderRadius = BorderRadius.circular(radius);

    Widget panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        // 左上をわずかに明るくして、板に厚みがあるように見せる
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: (fill + 0.05).clamp(0.0, 1.0)),
            Colors.white.withValues(alpha: (fill - 0.03).clamp(0.0, 1.0)),
          ],
        ),
      ),
      child: child,
    );

    if (blurOn) {
      panel = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: panel,
      );
    }

    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: ClipRRect(borderRadius: borderRadius, child: panel),
    );
  }
}

/// ガラス板の上に置く小さな丸いボタン（「トラック一覧」「1番」「…」）。
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    this.tooltip,
    this.active = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final String? tooltip;

  /// オンの状態（緑を薄く敷く）
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = active
        ? scheme.primary.withValues(alpha: 0.18)
        : scheme.onSurface.withValues(alpha: 0.1);
    Widget pill = Material(
      color: fill,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (tooltip != null) pill = Tooltip(message: tooltip!, child: pill);
    return pill;
  }
}
