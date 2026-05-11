import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/subtitle_service.dart';

/// 字幕表示ウィジェット（1行表示、映画字幕風、固定高さ）
class KaraokeSubtitle extends ConsumerWidget {
  const KaraokeSubtitle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(subtitleModeProvider);
    if (mode != SubtitleMode.subtitle) return const SizedBox.shrink();

    final subtitles = ref.watch(subtitleDataProvider);
    if (subtitles == null || subtitles.isEmpty) return const SizedBox.shrink();

    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final current = _findCurrent(subtitles, position);

    // 固定高さ（2行分）で要素のガタつきを防止
    return SizedBox(
      height: 48,
      child: Center(
        child: current != null
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  current.text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    shadows: [
                      Shadow(color: Colors.black, blurRadius: 4),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }

  SubtitleEntry? _findCurrent(List<SubtitleEntry> subs, Duration pos) {
    for (final s in subs) {
      if (pos >= s.offset && pos < s.end) return s;
    }
    return null;
  }
}
