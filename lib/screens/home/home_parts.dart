import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/glass_surface.dart';

/// ホームの一覧（リスト表示・タグ・プレイリスト）を 1 枚のガラス面にまとめる。
/// 中の ListView は FAB とミニプレイヤーのぶん下に余白を取る（[listPadding]）
class HomeListSurface extends StatelessWidget {
  const HomeListSurface({super.key, required this.child});

  final Widget child;

  /// 面の中の ListView に渡す余白（上 4、下は FAB のぶん）
  static const listPadding = EdgeInsets.only(top: 4, bottom: 80);

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return GlassSurface(
      margin: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, bottomPad + AppSpacing.lg),
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
    );
  }
}
