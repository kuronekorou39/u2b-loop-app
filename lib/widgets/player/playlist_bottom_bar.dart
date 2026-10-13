import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/playlist_mode.dart' as pl;
import '../../providers/player_provider.dart';

/// プレイリスト再生画面の下部固定コントローラー。
///
/// 上段にシークバー、下段に「n / N」・シャッフル・前・再生(大)・次・リピート・「その他」。
/// 1番だけ・AB区間・音量正規化・速度・音量などは「その他」シート側に寄せ、
/// ここは常時使う操作だけにしている。
class PlaylistBottomBar extends ConsumerWidget {
  const PlaylistBottomBar({
    super.key,
    required this.seekbar,
    required this.trackLabel,
    required this.shuffle,
    required this.onShuffle,
    required this.repeatMode,
    required this.onRepeat,
    required this.onPrev,
    required this.onNext,
    required this.onMore,
  });

  final Widget seekbar;

  /// 「3 / 12」のような現在位置表示
  final String trackLabel;
  final bool shuffle;
  final VoidCallback? onShuffle;
  final pl.RepeatMode repeatMode;
  final VoidCallback onRepeat;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onMore;

  static const _playSize = 64.0;
  static const _skipSize = 38.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final hasSource = ref.watch(videoSourceProvider) != null;
    final player = ref.read(playerProvider);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    final (repeatIcon, repeatColor) = switch (repeatMode) {
      pl.RepeatMode.none => (Icons.repeat, Colors.grey),
      pl.RepeatMode.all => (Icons.repeat, AppTheme.accentGreen),
      pl.RepeatMode.single => (Icons.repeat_one, AppTheme.accentGreen),
    };
    final repeatTooltip = switch (repeatMode) {
      pl.RepeatMode.none => 'リピートなし',
      pl.RepeatMode.all => '全曲リピート',
      pl.RepeatMode.single => '1曲リピート',
    };

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(0, AppSpacing.xs, 0, AppSpacing.sm + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          seekbar,
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    trackLabel,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      color: Colors.grey,
                      fontFeatures: const [FontFeature('tnum')],
                    ),
                  ),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          size: AppIconSizes.md,
                          color: shuffle ? AppTheme.accentGreen : Colors.grey,
                        ),
                        onPressed: onShuffle,
                        tooltip: 'シャッフル',
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_previous_rounded, size: _skipSize),
                        onPressed: onPrev,
                        tooltip: '前の曲',
                        visualDensity: VisualDensity.compact,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                        child: _PlayButton(
                          playing: playing,
                          enabled: hasSource,
                          onTap: () => player.playOrPause(),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next_rounded, size: _skipSize),
                        onPressed: onNext,
                        tooltip: '次の曲',
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        icon: Icon(repeatIcon, size: AppIconSizes.md, color: repeatColor),
                        onPressed: onRepeat,
                        tooltip: repeatTooltip,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: IconButton.filledTonal(
                      icon: const Icon(Icons.more_horiz, size: AppIconSizes.lg),
                      onPressed: onMore,
                      tooltip: 'その他',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.enabled,
    required this.onTap,
  });

  final bool playing;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Material(
      color: enabled ? color : color.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      elevation: enabled ? 4 : 0,
      shadowColor: color.withValues(alpha: 0.6),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: PlaylistBottomBar._playSize,
          height: PlaylistBottomBar._playSize,
          child: Tooltip(
            message: playing ? '一時停止' : '再生',
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: PlaylistBottomBar._playSize * 0.62,
              color: AppTheme.darkBackground,
            ),
          ),
        ),
      ),
    );
  }
}
