import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../models/loop_item.dart';
import '../models/loop_region.dart';
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
          Text(data.name,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text('$youtubeCount 曲',
              style: const TextStyle(fontSize: 13)),
          if (regionCount > 0)
            Text('$regionCount 個のAB区間',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          if (tagNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                children: tagNames
                    .map((t) => Chip(
                          label: Text(t, style: const TextStyle(fontSize: 11)),
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

    // タグ名→IDマッピング（既存タグは再利用、なければ作成）
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

    // アイテム作成
    final itemIds = <String>[];
    for (final si in data.items) {
      if (si.videoId.isEmpty) continue;

      // 既存チェック
      final existing =
          itemBox.values.where((i) => i.videoId == si.videoId).firstOrNull;
      if (existing != null) {
        itemIds.add(existing.id);
        // 区間をマージ（既存にないものだけ追加）
        for (final sr in si.regions) {
          if (!existing.regions.any((r) => r.name == sr.name)) {
            existing.regions
                .add(sr.toLoopRegion('${existing.id}_r${existing.regions.length}'));
          }
        }
        // タグをマージ
        for (final tagName in si.tags) {
          final tagId = tagNameToId[tagName];
          if (tagId != null && !existing.tagIds.contains(tagId)) {
            existing.tagIds.add(tagId);
          }
        }
        await itemBox.put(existing.id, existing);
        continue;
      }

      // 新規作成
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
        fetchStatus: null,
        tagIds: tagIds,
        regions: regions,
      );
      await itemBox.put(id, item);
      itemIds.add(id);
      // 連続追加ディレイ
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // プレイリスト作成
    final plId = DateTime.now().microsecondsSinceEpoch.toString();
    final playlist = Playlist(
      id: plId,
      name: data.name,
      itemIds: itemIds,
    );
    await Hive.box<Playlist>('playlists').put(plId, playlist);

    // プロバイダ更新
    ref.invalidate(loopItemsProvider);
    ref.invalidate(playlistsProvider);
    ref.invalidate(tagsProvider);

    // サムネ取得
    ref.read(loopItemsProvider.notifier).repairThumbnails();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('「${data.name}」をインポートしました（${itemIds.length}曲）'),
        ),
      );
    }
  }
}
