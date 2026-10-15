import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/playlist_track.dart';
import '../marquee_text.dart';
import 'track_row_parts.dart';

/// 動画の下に出す「いま何を聴いているか」: 曲名、補足（BPM・キーなど）、右にチップ。
/// チップはモードごと（プレイリスト: 次の曲 [NextTrackChip]、単体: いまの区間 [HeaderChip]）。
class NowPlayingHeader extends StatelessWidget {
  const NowPlayingHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.chip,
  });

  final String title;
  final String subtitle;
  final Widget? chip;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final sub = textTheme.labelSmall!.copyWith(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7));
    final titleStyle = textTheme.titleLarge!.copyWith(fontSize: 17);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl + 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarqueeText(text: title, style: titleStyle),
                const SizedBox(height: 3),
                Text(subtitle, style: sub),
              ],
            ),
          ),
          if (chip != null) ...[
            const SizedBox(width: AppSpacing.lg),
            chip!,
          ],
        ],
      ),
    );
  }
}

/// 曲名行の右に置く小さなチップ: 先頭に [leading]、緑の小さな [label] と本文 [text]
class HeaderChip extends StatelessWidget {
  const HeaderChip({
    super.key,
    required this.leading,
    required this.label,
    required this.text,
    required this.onTap,
  });

  final Widget leading;
  final String label;
  final String text;
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
          padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading,
                const SizedBox(width: AppSpacing.md),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        // 以前は 9px で読めなかった。labelSmall（11px）のまま
                        style: textTheme.labelSmall!
                            .copyWith(color: AppTheme.accentGreen),
                      ),
                      Text(
                        text,
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

/// プレイリスト用: 次に鳴る曲のチップ（サムネ付き）
class NextTrackChip extends StatelessWidget {
  const NextTrackChip({super.key, required this.track, required this.onTap});

  final PlaylistTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HeaderChip(
      leading: TrackThumb(track: track, width: 34, height: 26),
      label: '次',
      text: track.displayName,
      onTap: onTap,
    );
  }
}
