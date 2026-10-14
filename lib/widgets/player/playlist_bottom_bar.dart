import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/playlist_mode.dart' as pl;
import '../../providers/player_provider.dart';
import '../glass_panel.dart';

/// プレイリスト再生画面の下部コントローラー（ガラス板）。
///
/// 上からシーク領域・シャッフル/前/再生(大)/次/リピート・ピル（トラック一覧・1番・その他）。
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

  static const playSize = 76.0;
  static const playSizeCompact = 60.0;
  static const _skipSize = 44.0;

  /// 板の外側の余白（横と、画面下端との間）
  static const margin = 12.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final hasSource = ref.watch(videoSourceProvider) != null;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

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

    return GlassPanel(
      // 下はジェスチャーバー/ナビバーの分（bottomInset）に加えて余白をとる。
      // 画面の最下段は指が触れにくく、詰めると窮屈に見える
      margin: EdgeInsets.fromLTRB(
          margin, 0, margin, AppSpacing.xl + bottomInset),
      padding: EdgeInsets.fromLTRB(
          2, compact ? AppSpacing.lg : AppSpacing.xl + 2, 2, compact ? AppSpacing.xl : AppSpacing.xl + 4),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            seekbar,
            SizedBox(height: compact ? AppSpacing.md : AppSpacing.xl),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ToggleIconButton(
                    icon: Icons.shuffle,
                    on: shuffle,
                    onPressed: onShuffle,
                    tooltip: 'シャッフル',
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded, size: _skipSize),
                    onPressed: onPrev,
                    tooltip: '前の曲',
                  ),
                  _PlayButton(
                    playing: playing,
                    enabled: hasSource,
                    size: compact ? playSizeCompact : playSize,
                    onTap: () => ref.read(playerProvider).playOrPause(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded, size: _skipSize),
                    onPressed: onNext,
                    tooltip: '次の曲',
                  ),
                  _ToggleIconButton(
                    icon: repeatIcon,
                    on: repeatOn,
                    onPressed: onRepeat,
                    tooltip: repeatTooltip,
                  ),
                ],
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: AppSpacing.xl + 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                child: Row(
                  children: [
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
                          Icon(Icons.keyboard_arrow_up,
                              size: AppIconSizes.sm, color: dim),
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
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// シャッフル・リピートのようなオン/オフのあるボタン。オンなら緑の丸を敷く
class _ToggleIconButton extends StatelessWidget {
  const _ToggleIconButton({
    required this.icon,
    required this.on,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final bool on;
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final off = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return IconButton(
      icon: Icon(icon, size: AppIconSizes.ml),
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: on ? AppTheme.accentGreen : off,
        backgroundColor:
            on ? AppTheme.accentGreen.withValues(alpha: 0.18) : null,
        fixedSize: const Size.square(44),
      ),
    );
  }
}

/// 大きな再生ボタン。緑のグラデーションに淡い発光
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.enabled,
    required this.size,
    required this.onTap,
  });

  final bool playing;
  final bool enabled;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const color = AppTheme.accentGreen;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: enabled
              ? const [Color(0xFF7CE8C4), color]
              : [color.withValues(alpha: 0.35), color.withValues(alpha: 0.3)],
        ),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: Tooltip(
            message: playing ? '一時停止' : '再生',
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: size * 0.56,
              color: AppTheme.darkBackground,
            ),
          ),
        ),
      ),
    );
  }
}
