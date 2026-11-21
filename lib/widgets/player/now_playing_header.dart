import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/playlist_track.dart';
import '../../providers/player_provider.dart';
import '../settings/hq_audio_log_dialog.dart';
import '../marquee_text.dart';
import 'track_row_parts.dart';

/// 動画の下に出す「いま何を聴いているか」: 曲名（1 行目を幅いっぱい）、2 行目に補足（BPM・キーなど）と
/// 右寄せのチップ。チップはモードごと（プレイリスト: 次の曲 [NextTrackChip]、単体: いまの区間
/// [HeaderChip]）。以前は曲名の行の右にあり、曲名が短く切れていた。横画面ではチップを
/// 右の列に出すので、ここには渡さない（PlayerShell.wideChip）。
/// 補足の行末に、いま鳴っている音声の素性（高音質 / 標準 / オフライン / ローカル）も出す。
/// 高音質は落とせないと黙って標準に戻るので、ここで気づけるようにしてある
class NowPlayingHeader extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final sub = textTheme.labelSmall!.copyWith(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7));
    final titleStyle = textTheme.titleLarge!.copyWith(fontSize: 17);
    final quality = ref.watch(activeAudioQualityProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarqueeText(text: title, style: titleStyle),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (subtitle.isNotEmpty)
                      Flexible(
                        child: Text(subtitle,
                            style: sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    if (quality != null) ...[
                      if (subtitle.isNotEmpty) Text('  ·  ', style: sub),
                      // タップで高音質のログ（付かなかった理由をその場で読める）
                      GestureDetector(
                        onTap: () => HqAudioLogDialog.show(context),
                        child: Text(
                          quality.label,
                          style: sub.copyWith(
                            color: quality.isHq
                                ? AppTheme.accentGreen
                                : AppTheme.muted(context),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (chip != null) ...[
                const SizedBox(width: AppSpacing.lg),
                chip!,
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 曲名の下の行の右（横画面は右の列の上）に置く小さなチップ: 先頭に [leading]、
/// 緑の小さな [label] と本文 [text] を 1 行に
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

  /// 幅の上限（補足の行と分け合うので長い曲名・区間名は切る）
  static const maxWidth = 200.0;

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
          padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading,
                const SizedBox(width: AppSpacing.sm),
                Text(
                  label,
                  // 以前は 9px で読めなかった。labelSmall（11px）のまま
                  style: textTheme.labelSmall!
                      .copyWith(color: AppTheme.accentGreen),
                ),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    text,
                    style: textTheme.labelMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
      leading: TrackThumb(track: track, width: 32, height: 22),
      label: '次',
      text: track.displayName,
      onTap: onTap,
    );
  }
}
