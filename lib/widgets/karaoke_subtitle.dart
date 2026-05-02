import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_theme.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/subtitle_service.dart';

/// カラオケ風字幕表示ウィジェット
/// 再生位置に応じて字幕テキストをハイライト
class KaraokeSubtitle extends ConsumerWidget {
  const KaraokeSubtitle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(subtitleVisibleProvider);
    if (!visible) return const SizedBox.shrink();

    final subtitles = ref.watch(subtitleDataProvider);
    if (subtitles == null || subtitles.isEmpty) return const SizedBox.shrink();

    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;

    // 現在の字幕を検索
    final current = _findCurrent(subtitles, position);
    if (current == null) return const SizedBox(height: 48);

    // 字幕内の進行率 (0.0 ~ 1.0)
    final progress = _calcProgress(current, position);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: current.parts.isNotEmpty
          ? _buildPartsHighlight(context, current, position)
          : _buildGradientHighlight(context, current.text, progress),
    );
  }

  SubtitleEntry? _findCurrent(List<SubtitleEntry> subs, Duration pos) {
    for (final s in subs) {
      if (pos >= s.offset && pos < s.end) return s;
    }
    return null;
  }

  double _calcProgress(SubtitleEntry entry, Duration pos) {
    final elapsed = (pos - entry.offset).inMilliseconds;
    final total = entry.duration.inMilliseconds;
    if (total <= 0) return 1.0;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  /// パーツ（単語）レベルのハイライト
  Widget _buildPartsHighlight(
      BuildContext context, SubtitleEntry entry, Duration pos) {
    final elapsed = pos - entry.offset;
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        children: entry.parts.map((part) {
          final isActive = elapsed >= part.offset;
          return TextSpan(
            text: part.text,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isActive
                  ? AppTheme.accentGreen
                  : Colors.white.withValues(alpha: 0.5),
              shadows: isActive
                  ? [Shadow(color: AppTheme.accentGreen.withValues(alpha: 0.4),
                      blurRadius: 8)]
                  : null,
            ),
          );
        }).toList(),
      ),
    );
  }

  /// グラデーション（文字レベル）のハイライト
  Widget _buildGradientHighlight(
      BuildContext context, String text, double progress) {
    final highlightedChars = (text.length * progress).round();
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        children: [
          // ハイライト済み
          TextSpan(
            text: text.substring(0, highlightedChars),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.accentGreen,
              shadows: [
                Shadow(
                    color: AppTheme.accentGreen.withValues(alpha: 0.4),
                    blurRadius: 8),
              ],
            ),
          ),
          // 未ハイライト
          TextSpan(
            text: text.substring(highlightedChars),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}
