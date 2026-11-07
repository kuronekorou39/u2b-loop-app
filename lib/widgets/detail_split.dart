import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 詳細画面（曲・プレイリスト）の横画面: 左の列にサムネを大きく・見出し・ボタン、
/// 右に中身。横は AppBar を置かず、左の列の一番上に [DetailSplitTopBar] を置く
/// （右の中身を画面の上まで使う）
class DetailSplit {
  DetailSplit._();

  /// 左右に分ける最小の幅
  static const minWidth = 600.0;

  static bool of(Size size) =>
      size.width > size.height && size.width >= minWidth;

  /// 左の列の幅
  static double sideWidth(Size size) =>
      (size.width * 0.42).clamp(320.0, 480.0).toDouble();
}

/// 横画面の左の列の一番上: 戻る・画面名・操作（AppBar の代わり）
class DetailSplitTopBar extends StatelessWidget {
  const DetailSplitTopBar({super.key, required this.title, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const BackButton(),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ...actions,
      ],
    );
  }
}
