import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_theme.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/subtitle_service.dart';

/// Apple Music風リリクス表示（動画に重ねる半透明オーバーレイ）
class LyricsOverlay extends ConsumerStatefulWidget {
  const LyricsOverlay({super.key});

  @override
  ConsumerState<LyricsOverlay> createState() => _LyricsOverlayState();
}

class _LyricsOverlayState extends ConsumerState<LyricsOverlay> {
  int _lastIndex = -1;
  final _currentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(subtitleModeProvider);
    if (mode != SubtitleMode.lyrics) return const SizedBox.shrink();

    final subtitles = ref.watch(subtitleDataProvider);
    if (subtitles == null || subtitles.isEmpty) return const SizedBox.shrink();

    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final currentIdx = _findCurrentIndex(subtitles, position);

    // 自動スクロール（GlobalKeyでカレント行の実際の位置にスクロール）
    if (currentIdx != _lastIndex) {
      _lastIndex = currentIdx;
      if (currentIdx >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _currentKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              alignment: 0.35, // 画面の35%の位置に表示
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
            );
          }
        });
      }
    }

    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      child: ListView.builder(
        padding: EdgeInsets.only(
          top: 32,
          bottom: MediaQuery.sizeOf(context).height * 0.5,
          left: 16,
          right: 16,
        ),
        itemCount: subtitles.length,
        itemBuilder: (ctx, i) {
          final entry = subtitles[i];
          final isCurrent = i == currentIdx;
          final isPast = (currentIdx >= 0 && i < currentIdx) ||
              (currentIdx == -1 && position >= subtitles[i].end);

          return GestureDetector(
            key: isCurrent ? _currentKey : null,
            onTap: () {
              ref.read(playerProvider).seek(entry.offset);
            },
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: isCurrent ? 8 : 4,
              ),
              child: isCurrent
                  ? _buildHighlightedLine(entry, position)
                  : Text(
                      entry.text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: isPast
                            ? Colors.white.withValues(alpha: 0.3)
                            : Colors.white.withValues(alpha: 0.6),
                        height: 1.6,
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHighlightedLine(SubtitleEntry entry, Duration pos) {
    final elapsed = (pos - entry.offset).inMilliseconds;
    final total = entry.duration.inMilliseconds;
    final progress = total > 0 ? (elapsed / total).clamp(0.0, 1.0) : 1.0;
    final highlightedChars = (entry.text.length * progress).round();

    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        children: [
          TextSpan(
            text: entry.text.substring(0, highlightedChars),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.accentGreen,
              height: 1.6,
              shadows: [
                Shadow(
                    color: AppTheme.accentGreen.withValues(alpha: 0.4),
                    blurRadius: 8),
              ],
            ),
          ),
          TextSpan(
            text: entry.text.substring(highlightedChars),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white.withValues(alpha: 0.5),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  int _findCurrentIndex(List<SubtitleEntry> subs, Duration pos) {
    for (var i = subs.length - 1; i >= 0; i--) {
      if (pos >= subs[i].offset && pos < subs[i].end) return i;
    }
    return -1;
  }
}
