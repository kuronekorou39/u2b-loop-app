import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 横レイアウトで AppBar の代わりに動画の上へ出す 1 行:
/// 戻る・小さな題（プレイリスト名 / 「AB 設定」）・右側の操作。
/// 縦の AppBar と同じ操作を [actions] に渡す（再生画面と AB 設定画面で共用）
class PlayerWideTopBar extends StatelessWidget {
  const PlayerWideTopBar({
    super.key,
    required this.title,
    required this.actions,
  });

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '戻る',
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: Text(
              title,
              style: textTheme.labelMedium!
                  .copyWith(color: textTheme.bodySmall!.color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
