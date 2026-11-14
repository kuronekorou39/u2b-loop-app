import 'package:flutter/material.dart';

import '../../core/storage/app_boxes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/loop_item.dart';

/// 登録データの統計（詳細設定 > デバッグ）
class StatsDialog {
  StatsDialog._();

  static Future<void> show(BuildContext context) {
    final items = AppBoxes.loopItems.values.toList();
    final totalPlayCount = items.fold<int>(0, (sum, i) => sum + i.playCount);
    final totalRegions = items.fold<int>(0, (sum, i) => sum + i.regions.length);
    final youtubeCount = items.where((i) => i.isYouTube).length;
    final localCount = items.where((i) => i.isLocal).length;

    LoopItem? mostPlayed;
    LoopItem? oldest;
    if (items.isNotEmpty) {
      mostPlayed = items.reduce((a, b) => a.playCount >= b.playCount ? a : b);
      oldest = items.reduce((a, b) => a.createdAt.isBefore(b.createdAt) ? a : b);
    }

    // 総再生時間の推定（再生カウント × 平均3分）
    final estimatedMinutes = totalPlayCount * 3;

    return showDialog<void>(
      context: context,
      builder: (ctx) {
        final textTheme = Theme.of(ctx).textTheme;
        Widget line(String label, String value) => Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: textTheme.labelSmall),
                  Text(value, style: textTheme.bodyMedium),
                ],
              ),
            );
        return AlertDialog(
          title: Text('統計', style: textTheme.titleMedium),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line('登録曲数',
                    '${items.length} 曲（YouTube: $youtubeCount / ローカル: $localCount）'),
                line('プレイリスト', '${AppBoxes.playlists.length} 個'),
                line('タグ', '${AppBoxes.tags.length} 個'),
                line('AB区間', '$totalRegions 個'),
                line('総再生回数', '$totalPlayCount 回'),
                line('推定練習時間',
                    '約${estimatedMinutes ~/ 60}時間${estimatedMinutes % 60}分'),
                if (mostPlayed != null && mostPlayed.playCount > 0)
                  line('最多リピート',
                      '${mostPlayed.title}（${mostPlayed.playCount}回）'),
                if (oldest != null)
                  line('最古の登録',
                      '${oldest.createdAt.year}/${oldest.createdAt.month}/${oldest.createdAt.day}'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }
}
