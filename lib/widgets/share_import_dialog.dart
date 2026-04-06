import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../core/theme/app_theme.dart';
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

    // Notifier経由で枠を一括追加
    final notifier = ref.read(loopItemsProvider.notifier);
    final itemIds = await notifier.importSharedItems(data.items, tagNameToId);

    // プレイリスト作成
    final plId = DateTime.now().microsecondsSinceEpoch.toString();
    final playlist = Playlist(
      id: plId,
      name: data.name,
      itemIds: itemIds,
    );
    await Hive.box<Playlist>('playlists').put(plId, playlist);

    // UIを更新して完了通知
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
    if (itemIds.isNotEmpty) {
      notifier.fetchItemsInBackground(itemIds);
    }
  }
}
