import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/playlist_track.dart';
import '../marquee_text.dart';
import 'track_row_parts.dart';

/// 動画の下に出す「いま何を聴いているか」: 曲名、BPM・キー・n/N、次の曲のチップ。
/// 次曲チップをタップするとトラック一覧が開く。
class NowPlayingHeader extends StatelessWidget {
  const NowPlayingHeader({
    super.key,
    required this.track,
    required this.index,
    required this.count,
    required this.next,
    required this.onNextTap,
  });

  final PlaylistTrack? track;

  /// 現在のトラック番号（0 始まり）。不明なら null
  final int? index;
  final int count;

  /// 次に鳴る曲。無ければ null（最後の曲でリピート無し）
  final PlaylistTrack? next;
  final VoidCallback onNextTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final item = track?.item;
    final sub = textTheme.labelSmall!.copyWith(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7));
    final subParts = <String>[
      if (item?.bpm != null) 'BPM ${item!.bpm!.round()}',
      if (item?.musicalKey != null) item!.musicalKey!,
      index != null ? '${index! + 1} / $count' : '- / $count',
    ];
    final titleStyle = textTheme.titleLarge!.copyWith(fontSize: 17);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl + 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarqueeText(text: track?.displayName ?? '', style: titleStyle),
                const SizedBox(height: 3),
                Text(subParts.join('  ·  '), style: sub),
              ],
            ),
          ),
          if (next != null) ...[
            const SizedBox(width: AppSpacing.lg),
            _NextChip(track: next!, onTap: onNextTap),
          ],
        ],
      ),
    );
  }
}

class _NextChip extends StatelessWidget {
  const _NextChip({required this.track, required this.onTap});

  final PlaylistTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TrackThumb(track: track, width: 34, height: 26),
                const SizedBox(width: AppSpacing.md),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '次',
                        style: textTheme.labelSmall!.copyWith(
                            fontSize: 9, color: AppTheme.accentGreen),
                      ),
                      Text(
                        track.displayName,
                        style: textTheme.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
