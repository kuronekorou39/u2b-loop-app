import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../providers/thumbnail_queue_provider.dart';
import 'glass_panel.dart';

/// サムネイルをまとめて取得している間、画面の下（ミニプレイヤーの上）に出す帯。
/// 一時停止すると畳み、再開は設定の「データ」から
class ThumbnailQueueBar extends ConsumerWidget {
  const ThumbnailQueueBar({super.key});

  /// 帯の高さ（余白を除く）
  static const height = 52.0;

  /// 帯のまわりの余白
  static const margin = 12.0;

  /// 残り時間の表示
  static String etaLabel(Duration d) {
    if (d.inHours > 0) return '約${d.inHours}時間${d.inMinutes % 60}分';
    if (d.inMinutes > 0) return '約${d.inMinutes}分';
    return '1分未満';
  }

  /// 件数と残り時間（データ画面の行でも使う）
  static String progressLabel(ThumbnailQueueState s) =>
      '${s.done} / ${s.total}'
      '${s.remaining == null ? '' : ' · 残り ${etaLabel(s.remaining!)}'}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(thumbnailQueueProvider);
    if (s == null || s.paused) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    final vp = MediaQuery.viewPaddingOf(context);
    return GlassPanel(
      radius: 16,
      margin: EdgeInsets.fromLTRB(margin + vp.left, 0, margin + vp.right, 0),
      padding: const EdgeInsets.only(left: AppSpacing.lg, right: AppSpacing.xs),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'サムネイルを取得中',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (s.total > 0)
                        Text(progressLabel(s), style: textTheme.labelSmall),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  LinearProgressIndicator(
                    value: s.total > 0 ? s.done / s.total : null,
                    color: AppTheme.accentGreen,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            IconButton(
              icon: const Icon(Icons.pause),
              tooltip: '一時停止',
              onPressed: () => ref.read(thumbnailQueueProvider.notifier).pause(),
            ),
          ],
        ),
      ),
    );
  }
}
