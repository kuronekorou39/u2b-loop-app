import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../core/theme/app_theme.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import '../services/share_service.dart';

Future<void> showShareImportDialog(
    BuildContext context, WidgetRef ref, ShareData data) {
  return showDialog(
    context: context,
    builder: (ctx) => _ShareImportDialog(data: data, ref: ref),
  );
}

class _ShareImportDialog extends StatelessWidget {
  final ShareData data;
  final WidgetRef ref;

  const _ShareImportDialog({required this.data, required this.ref});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final youtubeCount =
        data.items.where((i) => i.videoId.isNotEmpty).length;
    final regionCount =
        data.items.fold<int>(0, (sum, i) => sum + i.regions.length);
    final tagNames =
        data.items.expand((i) => i.tags).toSet();

    return AlertDialog(
      title: const Text('プレイリストを受信'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(data.name, style: textTheme.displaySmall),
          SizedBox(height: AppSpacing.lg),
          Text('$youtubeCount 曲', style: textTheme.bodyMedium),
          if (regionCount > 0)
            Text('$regionCount 個のAB区間',
                style: textTheme.bodyMedium!
                    .copyWith(color: textTheme.bodySmall!.color)),
          if (tagNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Wrap(
                spacing: AppSpacing.xs,
                children: tagNames
                    .map((t) => Chip(
                          label: Text(t, style: textTheme.labelSmall),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            _import(context);
          },
          child: const Text('インポート'),
        ),
      ],
    );
  }

  void _import(BuildContext context) async {
    final itemBox = Hive.box<LoopItem>('loop_items');
    final tagBox = Hive.box<Tag>('tags');
    final existingTags = tagBox.values.toList();

    // タグの名前→ID変換テーブルを作成
    final tagNameToId = <String, String>{};
    for (final name in data.items.expand((i) => i.tags).toSet()) {
      final existing =
          existingTags.where((t) => t.name == name).firstOrNull;
      if (existing != null) {
        tagNameToId[name] = existing.id;
      } else {
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final tag = Tag(id: id, name: name);
        await tagBox.put(id, tag);
        tagNameToId[name] = id;
      }
    }

    // 枠を一括追加（fetchStatus: 'fetching' で個別ローディング表示）
    final itemIds = <String>[];
    final newItemIds = <String>[]; // 情報取得が必要な新規アイテム
    for (final si in data.items) {
      if (si.videoId.isEmpty) continue;

      final existing =
          itemBox.values.where((i) => i.videoId == si.videoId).firstOrNull;
      if (existing != null) {
        itemIds.add(existing.id);
        for (final sr in si.regions) {
          if (!existing.regions.any((r) => r.name == sr.name)) {
            existing.regions
                .add(sr.toLoopRegion('${existing.id}_r${existing.regions.length}'));
          }
        }
        for (final tagName in si.tags) {
          final tagId = tagNameToId[tagName];
          if (tagId != null && !existing.tagIds.contains(tagId)) {
            existing.tagIds.add(tagId);
          }
        }
        await itemBox.put(existing.id, existing);
        continue;
      }

      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final tagIds = si.tags
          .map((name) => tagNameToId[name])
          .whereType<String>()
          .toList();
      final regions = si.regions
          .asMap()
          .entries
          .map((e) => e.value.toLoopRegion('${id}_r${e.key}'))
          .toList();
      final item = LoopItem(
        id: id,
        title: si.title,
        uri: '',
        sourceType: 'youtube',
        videoId: si.videoId,
        youtubeUrl: 'https://youtu.be/${si.videoId}',
        thumbnailUrl:
            'https://img.youtube.com/vi/${si.videoId}/hqdefault.jpg',
        fetchStatus: 'fetching',
        tagIds: tagIds,
        regions: regions,
      );
      await itemBox.put(id, item);
      itemIds.add(id);
      newItemIds.add(id);
    }

    // プレイリスト作成
    final plId = DateTime.now().microsecondsSinceEpoch.toString();
    final playlist = Playlist(
      id: plId,
      name: data.name,
      itemIds: itemIds,
    );
    await Hive.box<Playlist>('playlists').put(plId, playlist);

    // UIを更新して完了通知
    ref.invalidate(loopItemsProvider);
    ref.invalidate(playlistsProvider);
    ref.invalidate(tagsProvider);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('「${data.name}」をインポートしました（${itemIds.length}曲）'),
        ),
      );
    }

    // バックグラウンドで各アイテムのYouTube情報を順次取得
    if (newItemIds.isNotEmpty) {
      ref.read(loopItemsProvider.notifier).fetchItemsInBackground(newItemIds);
    }
  }
}
