import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/subtitle_service.dart';

/// 字幕表示ウィジェット（メイン+サブの2行、固定高さ）
class KaraokeSubtitle extends ConsumerWidget {
  const KaraokeSubtitle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(subtitleModeProvider);
    if (mode != SubtitleMode.subtitle) return const SizedBox.shrink();

    final mainSubs = ref.watch(subtitleDataProvider);
    final subSubs = ref.watch(subtitleSubDataProvider);
    if ((mainSubs == null || mainSubs.isEmpty) &&
        (subSubs == null || subSubs.isEmpty)) {
      return const SizedBox.shrink();
    }

    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final mainCurrent = _findCurrent(mainSubs, position);
    final subCurrent = _findCurrent(subSubs, position);

    final hasSubTrack = subSubs != null && subSubs.isNotEmpty;

    return SizedBox(
      height: hasSubTrack ? 64 : 48,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // メイン字幕
          if (mainCurrent != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                mainCurrent.text,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            )
          else
            const SizedBox(height: 18),
          // サブ字幕
          if (hasSubTrack) ...[
            const SizedBox(height: 2),
            if (subCurrent != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  subCurrent.text,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.6),
                    shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
              )
            else
              const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  SubtitleEntry? _findCurrent(List<SubtitleEntry>? subs, Duration pos) {
    if (subs == null) return null;
    for (final s in subs) {
      if (pos >= s.offset && pos < s.end) return s;
    }
    return null;
  }
}
