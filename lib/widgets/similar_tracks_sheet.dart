import 'package:flutter/material.dart';

import '../core/audio/musical_key.dart';
import '../core/audio/track_compatibility.dart';
import '../core/theme/app_theme.dart';
import '../models/loop_item.dart';
import 'item_thumbnail.dart';

/// ある曲と「つなぎやすい」曲をライブラリから探して並べるシート。
/// テンポ差（倍/半は折り畳む）とキーの Camelot 相性で順位付けする。
class SimilarTracksSheet extends StatelessWidget {
  const SimilarTracksSheet({
    super.key,
    required this.target,
    required this.candidates,
    required this.onSelect,
  });

  final LoopItem target;
  final List<LoopItem> candidates;
  final void Function(LoopItem item) onSelect;

  /// 表示する上限。これより下は相性が低く、見ても選ばない
  static const maxResults = 20;

  static Future<void> show(
    BuildContext context, {
    required LoopItem target,
    required Iterable<LoopItem> candidates,
    required void Function(LoopItem item) onSelect,
  }) {
    final ranked = TrackCompatibility.rank(target, candidates);
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SimilarTracksSheet(
        target: target,
        candidates: ranked.take(maxResults).toList(),
        onSelect: onSelect,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('つなぎやすい曲', style: textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '基準: ${[
                      ?target.bpmLabel,
                      if (target.musicalKey != null)
                        MusicalKey.display(target.musicalKey)!,
                    ].join(' · ')}',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Text('解析済みの曲が他にありません'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (_, i) {
                    final item = candidates[i];
                    final score = TrackCompatibility.score(target, item);
                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: AppRadius.borderXs,
                        child: SizedBox(
                          width: 64,
                          height: 36,
                          child: ItemThumbnail(
                              item: item, iconSize: AppIconSizes.sm),
                        ),
                      ),
                      title: Text(item.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(TrackCompatibility.describe(target, item),
                          style: textTheme.labelSmall),
                      trailing: _ScoreBadge(score: score),
                      onTap: () {
                        Navigator.pop(context);
                        onSelect(item);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 相性を 0〜100 の数字で出す（高いほど緑）
class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score});

  final double score;

  @override
  Widget build(BuildContext context) {
    final color = Color.lerp(AppTheme.accentRed, AppTheme.accentGreen, score)!;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: AppRadius.borderXs,
      ),
      child: Text(
        '${(score * 100).round()}',
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}
