import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/glass_surface.dart';

/// ホームの一覧（リスト表示・タグ・プレイリスト）を 1 枚のガラス面にまとめる。
/// 中の ListView は FAB とミニプレイヤーのぶん下に余白を取る（[listPadding]）。
/// 横画面では行が間延びしないよう、幅を [maxWidth] までにして真ん中に置く
class HomeListSurface extends StatelessWidget {
  const HomeListSurface({super.key, required this.child});

  final Widget child;

  /// 面の中の ListView に渡す余白（上 4、下は FAB のぶん）
  static const listPadding = EdgeInsets.only(top: 4, bottom: 80);

  /// 面の外の余白も含めた幅の上限
  static const maxWidth = 720.0;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return LayoutBuilder(
      builder: (context, c) => Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: math.min(c.maxWidth, maxWidth),
          height: c.maxHeight,
          child: GlassSurface(
            margin: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs,
                AppSpacing.lg, bottomPad + AppSpacing.lg),
            child: ClipRRect(
                borderRadius: BorderRadius.circular(16), child: child),
          ),
        ),
      ),
    );
  }
}
