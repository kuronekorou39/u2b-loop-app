import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/subtitle_provider.dart';

/// 字幕の表示モード切替ボタン（オフ → 字幕 → 歌詞 → オフ）。
/// 長押しで言語選択（[onLongPress]）。
/// 字幕が無い動画では何も表示しない。取得中はスピナー。
class SubtitleToggleButton extends ConsumerWidget {
  const SubtitleToggleButton({super.key, required this.onLongPress});

  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subtitleDataProvider);
    final mode = ref.watch(subtitleModeProvider);
    final loading = ref.watch(subtitleLoadingProvider);

    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (subs == null || subs.isEmpty) return const SizedBox.shrink();

    final IconData icon;
    final Color color;
    final String name;
    switch (mode) {
      case SubtitleMode.off:
        icon = Icons.subtitles_off;
        color = AppTheme.muted(context);
        name = 'オフ';
      case SubtitleMode.subtitle:
        icon = Icons.subtitles;
        color = AppTheme.accentGreen;
        name = 'カラオケ';
      case SubtitleMode.lyrics:
        icon = Icons.lyrics;
        color = AppTheme.accentGreen;
        name = '歌詞';
    }

    return GestureDetector(
      onLongPress: onLongPress,
      child: IconButton(
        icon: Icon(icon, size: AppIconSizes.md, color: color),
        tooltip: '字幕: $name（タップで切替、長押しで言語）',
        onPressed: () {
          ref.read(subtitleModeProvider.notifier).state = switch (mode) {
            SubtitleMode.off => SubtitleMode.subtitle,
            SubtitleMode.subtitle => SubtitleMode.lyrics,
            SubtitleMode.lyrics => SubtitleMode.off,
          };
        },
      ),
    );
  }
}
