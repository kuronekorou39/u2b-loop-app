import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/loop_item.dart';

/// アイテムのサムネイル。
/// サムネ未取得・読み込み失敗時はソース種別に応じたアイコンを表示する。
///
/// [heroTag] を渡した場合のみ Hero でラップする。
/// **詳細画面へ遷移するアイテムカードにだけ付けること。**
/// プレイリストのサムネにも付けると、同じ曲をサムネにしたプレイリストと
/// そのアイテム自身が同一画面に並んだときにタグが重複してdebugビルドでクラッシュする。
class ItemThumbnail extends StatelessWidget {
  const ItemThumbnail({
    super.key,
    required this.item,
    this.iconSize,
    this.heroTag,
    this.placeholder,
  });

  final LoopItem item;

  /// プレースホルダのアイコンサイズ（null ならテーマ既定）
  final double? iconSize;

  /// Hero遷移のタグ。null ならHeroでラップしない
  final String? heroTag;

  /// 既定のプレースホルダを差し替えたい場合に指定する
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final fallback = placeholder ?? _defaultPlaceholder(context);
    Widget content;
    final path = item.thumbnailPath;
    if (path != null) {
      content = Image.file(File(path),
          fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
    } else {
      content = fallback;
    }
    final tag = heroTag;
    return tag == null ? content : Hero(tag: tag, child: content);
  }

  Widget _defaultPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          item.isYouTube
              ? Icons.play_circle_outline
              : Icons.video_file_outlined,
          color: AppTheme.muted(context),
          size: iconSize,
        ),
      ),
    );
  }
}

/// 詳細画面など、サムネが無いときに説明文まで出したい場所向けのプレースホルダ。
class ItemThumbnailPlaceholderLarge extends StatelessWidget {
  const ItemThumbnailPlaceholderLarge({super.key, required this.item});

  final LoopItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            item.isYouTube
                ? Icons.play_circle_outline
                : Icons.video_file_outlined,
            size: AppIconSizes.xxl,
            color: AppTheme.muted(context),
          ),
          if (item.isLocal)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('ローカルファイル',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppTheme.muted(context))),
            ),
        ],
      ),
    );
  }
}
