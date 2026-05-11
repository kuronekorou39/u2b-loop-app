import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/subtitle_service.dart';

/// 字幕表示ウィジェット（1行表示、映画字幕風）
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
    if (current == null) return const SizedBox(height: 40);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        current.text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 15,
          color: Colors.white,
          shadows: [
            Shadow(color: Colors.black, blurRadius: 4),
          ],
        ),
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
