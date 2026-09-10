import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/playlist_track.dart';
import '../../models/tag.dart';

/// プレイリストのトラック行に使うサムネイル。
/// サムネ未取得・読み込み失敗時はソース種別に応じたアイコンを表示する。
class TrackThumb extends StatelessWidget {
  const TrackThumb({
    super.key,
    required this.track,
    this.width = 40,
    this.height = 30,
  });

  final PlaylistTrack track;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final path = track.item.thumbnailPath;
    return ClipRRect(
      borderRadius: AppRadius.borderXs,
      child: SizedBox(
        width: width,
        height: height,
        child: path != null
            ? Image.file(File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(context))
            : _placeholder(context),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        track.item.sourceType == 'youtube'
            ? Icons.play_circle_outline
            : Icons.video_file_outlined,
        size: AppIconSizes.s,
        color: Colors.grey,
      ),
    );
  }
}

/// トラック行のタイトル。再生中は緑の太字、無効化トラックはグレー。
class TrackTitleText extends StatelessWidget {
  const TrackTitleText({
    super.key,
    required this.track,
    required this.isCurrent,
  });

  final PlaylistTrack track;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    return Text(
      track.displayName,
      style: Theme.of(context).textTheme.labelMedium!.copyWith(
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
            color: isCurrent
                ? AppTheme.accentGreen
                : track.enabled
                    ? null
                    : Colors.grey,
          ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// トラック行に並べるタグチップ（最大2件）。タグ無しなら空リスト。
/// Row の children に `...` で展開して使う。
List<Widget> trackTagChips(
  BuildContext context,
  PlaylistTrack track,
  Map<String, Tag> tagMap,
) {
  final itemTags =
      track.item.tagIds.map((id) => tagMap[id]).whereType<Tag>().take(2).toList();
  if (itemTags.isEmpty) return const [];

  return [
    const SizedBox(width: AppSpacing.xs),
    for (final tag in itemTags)
      Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 72),
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 0),
          decoration: BoxDecoration(
            color: tag.color.withValues(alpha: 0.25),
            borderRadius: AppRadius.borderXs,
          ),
          child: Text(
            tag.name,
            style:
                Theme.of(context).textTheme.labelSmall!.copyWith(fontSize: 9),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
  ];
}
