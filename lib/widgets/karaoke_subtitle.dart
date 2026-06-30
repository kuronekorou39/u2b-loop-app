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
          // メイン字幕（半透明黒の背景ボックスで見やすく）
          if (mainCurrent != null)
            Center(
              child: Container(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.92),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  mainCurrent.text,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                ),
              ),
            )
          else
            const SizedBox(height: 18),
          // サブ字幕
          if (hasSubTrack) ...[
            const SizedBox(height: 2),
            if (subCurrent != null)
              Center(
                child: Container(
                  constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.92),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    subCurrent.text,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
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
