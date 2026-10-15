import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/playlist_service.dart';

/// YouTube プレイリストの取り込みで「個別に選択」を選んだときのページ。
/// 登録済みの動画は外した状態で始まり、追加する動画をチェックで選ぶ
class PlaylistVideoSelectPage extends StatefulWidget {
  const PlaylistVideoSelectPage({
    super.key,
    required this.videos,
    required this.duplicateIds,
    required this.playlistTitle,
    required this.onConfirm,
  });

  final List<PlaylistVideoInfo> videos;
  final Set<String> duplicateIds;
  final String playlistTitle;
  final void Function(List<PlaylistVideoInfo> selected) onConfirm;

  @override
  State<PlaylistVideoSelectPage> createState() =>
      _PlaylistVideoSelectPageState();
}

class _PlaylistVideoSelectPageState extends State<PlaylistVideoSelectPage> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    // デフォルトで新規のものを全選択
    _selected = widget.videos
        .where((v) => !widget.duplicateIds.contains(v.id))
        .map((v) => v.id)
        .toSet();
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final selectedCount = _selected.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlistTitle,
            style: textTheme.bodyLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          FilledButton(
            onPressed: selectedCount == 0
                ? null
                : () {
                    final selected = widget.videos
                        .where((v) => _selected.contains(v.id))
                        .toList();
                    widget.onConfirm(selected);
                    Navigator.pop(context);
                  },
            child: Text('追加 ($selectedCount)'),
          ),
          const SizedBox(width: AppSpacing.md),
        ],
      ),
      body: Column(
        children: [
          // 一括選択バー
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
            child: Row(
              children: [
                Text('${widget.videos.length}件中 $selectedCount件選択',
                    style: textTheme.bodySmall),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _selected = widget.videos.map((v) => v.id).toSet();
                  }),
                  child: Text('すべて選択', style: textTheme.labelMedium),
                ),
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: Text('すべて解除', style: textTheme.labelMedium),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.videos.length,
              itemBuilder: (context, i) {
                final video = widget.videos[i];
                final id = video.id;
                final isDuplicate = widget.duplicateIds.contains(id);
                final isSelected = _selected.contains(id);

                return ListTile(
                  leading: ClipRRect(
                    borderRadius: AppRadius.borderXs,
                    child: SizedBox(
                      width: 64,
                      height: 36,
                      child: Image.network(
                        video.thumbnailLowUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Icon(Icons.play_circle_outline,
                              color: AppTheme.muted(context),
                              size: AppIconSizes.sm),
                        ),
                      ),
                    ),
                  ),
                  title: Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium,
                  ),
                  subtitle: isDuplicate
                      ? Text('登録済み',
                          style: textTheme.labelSmall
                              ?.copyWith(color: Colors.orange))
                      : null,
                  trailing: Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggle(id),
                  ),
                  onTap: () => _toggle(id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
