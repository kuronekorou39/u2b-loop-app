import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/playlist_mode.dart' as pl;
import '../../providers/player_provider.dart';
import '../glass_panel.dart';
import 'player_glass_bar.dart';

/// プレイリスト再生画面の下部コントローラー（[PlayerGlassBar] の中身）。
///
/// シーク領域 / シャッフル・前・再生(大)・次・リピート / ピル（トラック一覧・1番・その他）。
/// トラック一覧を開いている間は [compact]（波形を低く、再生ボタンを小さく、ピル行なし）で、
/// 一覧側の見出しから閉じたり「その他」を開いたりできる。
/// 1番だけ以外の補助機能（AB区間・音量正規化・速度・音量）は「その他」シート側。
class PlaylistBottomBar extends ConsumerWidget {
  const PlaylistBottomBar({
    super.key,
    required this.seekbar,
    required this.compact,
    required this.shuffle,
    required this.onShuffle,
    required this.repeatMode,
    required this.onRepeat,
    required this.onPrev,
    required this.onNext,
    required this.onMore,
    required this.onToggleList,
    required this.firstVerse,
    required this.onToggleFirstVerse,
  });

  final Widget seekbar;

  /// トラック一覧を開いている間の低い形
  final bool compact;
  final bool shuffle;
  final VoidCallback? onShuffle;
  final pl.RepeatMode repeatMode;
  final VoidCallback onRepeat;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onMore;
  final VoidCallback onToggleList;
  final bool firstVerse;
  final VoidCallback onToggleFirstVerse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final hasSource = ref.watch(videoSourceProvider) != null;

    final (repeatIcon, repeatOn) = switch (repeatMode) {
      pl.RepeatMode.none => (Icons.repeat, false),
      pl.RepeatMode.all => (Icons.repeat, true),
      pl.RepeatMode.single => (Icons.repeat_one, true),
    };
    final repeatTooltip = switch (repeatMode) {
      pl.RepeatMode.none => 'リピートなし',
      pl.RepeatMode.all => '全曲リピート',
      pl.RepeatMode.single => '1曲リピート',
    };

    return PlayerGlassBar(
      seekbar: seekbar,
      compact: compact,
      transport: [
        ToggleIconButton(
          icon: Icons.shuffle,
          on: shuffle,
          onPressed: onShuffle,
          tooltip: 'シャッフル',
        ),
        TransportIconButton(
          icon: Icons.skip_previous_rounded,
          onPressed: onPrev,
          tooltip: '前の曲',
        ),
        BigPlayButton(
          playing: playing,
          enabled: hasSource,
          size: compact
              ? PlayerGlassBar.playSizeCompact
              : PlayerGlassBar.playSize,
          onTap: () => ref.read(playerProvider).playOrPause(),
        ),
        TransportIconButton(
          icon: Icons.skip_next_rounded,
          onPressed: onNext,
          tooltip: '次の曲',
        ),
        ToggleIconButton(
          icon: repeatIcon,
          on: repeatOn,
          onPressed: onRepeat,
          tooltip: repeatTooltip,
        ),
      ],
      pills: [
        GlassPill(
          onTap: onToggleList,
          tooltip: 'トラック一覧を開く',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.queue_music, size: AppIconSizes.sm),
              const SizedBox(width: AppSpacing.sm),
              Text('トラック一覧', style: theme.textTheme.labelMedium),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.keyboard_arrow_up, size: AppIconSizes.sm, color: dim),
            ],
          ),
        ),
        const Spacer(),
        GlassPill(
          onTap: onToggleFirstVerse,
          active: firstVerse,
          tooltip: '1番だけ',
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.looks_one_outlined,
                size: AppIconSizes.sm,
                color: firstVerse ? AppTheme.accentGreen : dim,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '1番',
                style: theme.textTheme.labelMedium!.copyWith(
                  color: firstVerse ? AppTheme.accentGreen : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        GlassPill(
          onTap: onMore,
          tooltip: 'その他',
          padding: const EdgeInsets.all(9),
          child: const Icon(Icons.more_horiz, size: AppIconSizes.md),
        ),
      ],
    );
  }
}
