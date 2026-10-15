import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../models/playlist_track.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../providers/playlist_player_provider.dart';
import '../equalizer_icon.dart';
import '../glass_panel.dart';
import '../marquee_text.dart';
import 'player_shell.dart';
import 'track_row_parts.dart';

/// プレイリスト再生中の曲リスト（背景なし）。
/// - 縦画面: [TrackListPanel] の中に入る。行の高さは [rowHeight] で固定し、
///   開いたときに再生中の行まで送れるようにする
/// - [dense]: 全画面ドロワー用。行を詰め、高さは固定しない
///
/// 並びと再生中の行は playlistPlayerProvider から、タグは tagsProvider から読む
class TrackList extends ConsumerWidget {
  const TrackList({
    super.key,
    required this.onSelect,
    required this.onMenu,
    this.controller,
    this.dense = false,
    this.bottomInset = 0,
    this.preloadingIndex,
    this.preloadedIndex,
  });

  /// 通常の行の高さ
  static const rowHeight = 64.0;

  final void Function(int index) onSelect;
  final void Function(int index, PlaylistTrack track) onMenu;
  final ScrollController? controller;
  final bool dense;
  final double bottomInset;

  /// 次の曲を読み込み中 / 読み込み済みの行（「次」バッジ）
  final int? preloadingIndex;
  final int? preloadedIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plState = ref.watch(playlistPlayerProvider);
    final currentIdx = plState.currentTrackIndex;
    final allTags = ref.watch(tagsProvider);
    final tagMap = {for (final t in allTags) t.id: t};
    // タグ変更時にトラック一覧を再描画するために監視
    ref.watch(loopItemsProvider);

    return ListView.builder(
      controller: controller,
      itemExtent: dense ? null : rowHeight,
      padding: EdgeInsets.only(
          bottom: bottomInset + (dense ? AppSpacing.xxl : AppSpacing.md)),
      itemCount: plState.tracks.length,
      itemBuilder: (ctx, i) => _TrackRow(
        index: i,
        track: plState.tracks[i],
        tagMap: tagMap,
        isCurrent: i == currentIdx,
        isPreloading: preloadingIndex == i,
        isPreloaded: preloadedIndex == i,
        dense: dense,
        onTap: () => onSelect(i),
        onMenu: () => onMenu(i, plState.tracks[i]),
      ),
    );
  }
}

/// 曲リストの 1 行: 状態 / サムネ / タイトル + BPM・キー・区間 / タグ / ⋮。
/// 再生中は緑の薄い帯、プリロード済みは「次」バッジ
class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.index,
    required this.track,
    required this.tagMap,
    required this.isCurrent,
    required this.isPreloading,
    required this.isPreloaded,
    required this.dense,
    required this.onTap,
    required this.onMenu,
  });

  final int index;
  final PlaylistTrack track;
  final Map<String, Tag> tagMap;
  final bool isCurrent;
  final bool isPreloading;
  final bool isPreloaded;
  final bool dense;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final Widget status;
    if (isCurrent) {
      status = const EqualizerIcon(color: AppTheme.accentGreen, size: 18);
    } else if (isPreloading) {
      status = const SizedBox(
        width: AppIconSizes.s,
        height: AppIconSizes.s,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
      );
    } else if (isPreloaded) {
      status = const Icon(Icons.check_circle_outline,
          color: AppTheme.accentGreen, size: AppIconSizes.sm);
    } else {
      status = Text('${index + 1}',
          style: textTheme.labelSmall, textAlign: TextAlign.center);
    }

    final titleStyle = textTheme.bodyMedium!.copyWith(
      fontSize: dense ? 13 : 14,
      fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
      color: isCurrent
          ? AppTheme.accentGreen
          : track.enabled
              ? null
              : AppTheme.muted(context),
    );

    final item = track.item;
    final subParts = <String>[
      ...item.musicInfoParts,
      if (track.hasRegion)
        '${TimeUtils.formatShortMs(track.startMs)} - ${TimeUtils.formatShortMs(track.endMs)}',
    ];

    return InkWell(
      onTap: onTap,
      onLongPress: onMenu,
      child: Container(
        decoration: BoxDecoration(
          color: isCurrent ? AppTheme.accentGreen.withValues(alpha: 0.12) : null,
          border: Border(
            top: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.06)),
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.lg + 2,
          vertical: dense ? AppSpacing.sm : AppSpacing.md + 2,
        ),
        child: Row(
          children: [
            SizedBox(width: AppIconSizes.lg, child: Center(child: status)),
            const SizedBox(width: AppSpacing.md),
            TrackThumb(
              track: track,
              width: dense ? 48 : 60,
              height: dense ? 36 : 44,
            ),
            const SizedBox(width: AppSpacing.md + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 再生中: マーキー、それ以外: 通常テキスト
                  if (isCurrent)
                    MarqueeText(text: track.displayName, style: titleStyle)
                  else
                    Text(
                      track.displayName,
                      style: titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (subParts.isNotEmpty || isPreloaded) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            subParts.join('  ·  '),
                            style: textTheme.labelSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isPreloaded) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppTheme.accentGreen.withValues(alpha: 0.18),
                              borderRadius: AppRadius.borderXs,
                            ),
                            child: Text(
                              '次',
                              style: textTheme.labelSmall!
                                  .copyWith(color: AppTheme.accentGreen),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // タグ: 右端に配置
            ...trackTagChips(context, track, tagMap),
            // メニューは長押しでも開くが、入口が見えるように ⋮ も置く
            IconButton(
              icon: Icon(Icons.more_vert,
                  size: AppIconSizes.sm,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5)),
              tooltip: 'メニュー',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
              onPressed: onMenu,
            ),
          ],
        ),
      ),
    );
  }
}

/// 開閉できるトラック一覧（動画の上に重ねるガラス板）。見出しに曲数。
/// 開閉はコントローラーの「トラック一覧」ピル（同じ場所で開いて閉じる）
class TrackListPanel extends ConsumerWidget {
  const TrackListPanel({super.key, required this.list});

  /// 中身（[TrackList]）
  final Widget list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackCount =
        ref.watch(playlistPlayerProvider.select((s) => s.trackCount));
    final textTheme = Theme.of(context).textTheme;
    return GlassPanel(
      key: const ValueKey('trackList'),
      margin: const EdgeInsets.fromLTRB(
          PlayerShell.margin, 0, PlayerShell.margin, AppSpacing.lg),
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      // 動画の上に乗るのでほぼ不透明な地を敷いて読めるようにし、ぼかしは使わない
      // （動画の上は重い）。0.86 では動画が透けて見づらかった
      blur: false,
      scrim: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.md),
            child: Row(
              children: [
                Text('トラック一覧', style: textTheme.titleSmall),
                const SizedBox(width: AppSpacing.md),
                Text('$trackCount 曲', style: textTheme.labelSmall),
              ],
            ),
          ),
          Expanded(child: list),
        ],
      ),
    );
  }
}
