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
  final ScrollController _scrollController = ScrollController();
  int _lastIndex = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(subtitleModeProvider);
    if (mode != SubtitleMode.lyrics) return const SizedBox.shrink();

    final subtitles = ref.watch(subtitleDataProvider);
    if (subtitles == null || subtitles.isEmpty) return const SizedBox.shrink();

    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final currentIdx = _findCurrentIndex(subtitles, position);

    // 自動スクロール
    if (currentIdx != _lastIndex && currentIdx >= 0) {
      _lastIndex = currentIdx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToIndex(currentIdx, subtitles.length);
      });
    }

    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        itemCount: subtitles.length + 1, // +1 for bottom spacer
        itemBuilder: (ctx, i) {
          // 末尾スペーサー（最終行を中央に表示するための余白）
          if (i >= subtitles.length) {
            return SizedBox(height: MediaQuery.sizeOf(context).height * 0.4);
          }

          final entry = subtitles[i];
          final isCurrent = i == currentIdx;
          // 間奏中(currentIdx==-1)は、endが過ぎた行を過去扱い
          final isPast = (currentIdx >= 0 && i < currentIdx) ||
              (currentIdx == -1 && position >= subtitles[i].end);

          return GestureDetector(
            onTap: () {
              ref.read(playerProvider).seek(entry.offset);
            },
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 300),
              style: TextStyle(
                fontSize: isCurrent ? 18 : 14,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                color: isCurrent
                    ? AppTheme.accentGreen
                    : isPast
                        ? Colors.white.withValues(alpha: 0.3)
                        : Colors.white.withValues(alpha: 0.6),
                height: 1.6,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: isCurrent ? 8 : 4,
                ),
                child: Text(
                  entry.text,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  int _findCurrentIndex(List<SubtitleEntry> subs, Duration pos) {
    for (var i = subs.length - 1; i >= 0; i--) {
      if (pos >= subs[i].offset && pos < subs[i].end) return i;
    }
    return -1;
  }

  void _scrollToIndex(int index, int total) {
    if (!_scrollController.hasClients) return;
    // 1行あたり推定高さ（current=42, other=30）
    final estimatedOffset = index * 30.0 - 60; // 少し手前に表示
    _scrollController.animateTo(
      estimatedOffset.clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }
}
