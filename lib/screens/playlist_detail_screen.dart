import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import 'detail_screen.dart';
import 'player_screen.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  Playlist? _findPlaylist() {
    return ref
        .read(playlistsProvider)
        .where((p) => p.id == widget.playlistId)
        .firstOrNull;
  }

  void _renamePlaylist(Playlist pl) async {
    final controller = TextEditingController(text: pl.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プレイリスト名変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('変更'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName != null && newName.isNotEmpty && newName != pl.name) {
      pl.name = newName;
      ref.read(playlistsProvider.notifier).update(pl);
    }
  }

  Future<void> _deletePlaylist(Playlist pl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${pl.name}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      ref.read(playlistsProvider.notifier).delete(pl.id);
      Navigator.of(context).pop();
    }
  }

  void _removeItem(Playlist pl, String itemId) {
    ref.read(playlistsProvider.notifier).removeItem(pl.id, itemId);
  }

  // --- アイテム追加 ---

  void _showAddSheet(Playlist pl) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('曲を追加',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.list),
              title: const Text('一覧から選択'),
              onTap: () {
                Navigator.pop(ctx);
                _showItemPicker(pl);
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('タグで一括追加'),
              onTap: () {
                Navigator.pop(ctx);
                _showTagPicker(pl);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showItemPicker(Playlist pl) {
    final allItems = ref.read(loopItemsProvider);
    final readyItems = allItems.where((i) => i.isReady).toList();
    final existing = Set<String>.from(pl.itemIds);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (ctx, scrollController) => _ItemPickerSheet(
          items: readyItems,
          existingIds: existing,
          scrollController: scrollController,
          onAdd: (ids) {
            ref
                .read(playlistsProvider.notifier)
                .addItems(pl.id, ids);
          },
        ),
      ),
    );
  }

  void _showTagPicker(Playlist pl) {
    final tags = ref.read(tagsProvider);
    final allItems = ref.read(loopItemsProvider);

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('タグで一括追加',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            if (tags.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('タグがありません',
                    style: TextStyle(color: Colors.grey)),
              ),
            for (final tag in tags)
              ListTile(
                leading: const Icon(Icons.label_outline, size: 20),
                title: Text(tag.name),
                subtitle: Text(
                  '${allItems.where((i) => i.tagIds.contains(tag.id) && i.isReady).length} 曲',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  ref
                      .read(playlistsProvider.notifier)
                      .addItemsByTag(pl.id, tag.id, allItems);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('「${tag.name}」の曲を追加しました'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final pl =
        playlists.where((p) => p.id == widget.playlistId).firstOrNull;
    final allItems = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);

    if (pl == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('プレイリスト')),
        body: const Center(child: Text('プレイリストが見つかりません')),
      );
    }

    // プレイリスト内のアイテムを取得（順序維持）
    final items = <LoopItem>[];
    for (final id in pl.itemIds) {
      final item = allItems.where((i) => i.id == id).firstOrNull;
      if (item != null) items.add(item);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(pl.name, style: const TextStyle(fontSize: 16)),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerScreen(
                    item: items.first,
                    playlistItems: items,
                  ),
                ),
              ),
              tooltip: '再生',
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') _renamePlaylist(pl);
              if (v == 'delete') _deletePlaylist(pl);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('名前変更')),
              const PopupMenuItem(
                  value: 'delete',
                  child: Text('削除', style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.playlist_play,
                      size: 64,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.3)),
                  const SizedBox(height: 12),
                  Text('曲がありません',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5))),
                  const SizedBox(height: 4),
                  Text('＋ ボタンで追加',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.3))),
                ],
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: items.length,
              onReorder: (oldIdx, newIdx) {
                if (newIdx > oldIdx) newIdx--;
                final id = pl.itemIds.removeAt(oldIdx);
                pl.itemIds.insert(newIdx, id);
                ref.read(playlistsProvider.notifier).update(pl);
              },
              itemBuilder: (context, i) {
                final item = items[i];
                final itemTags =
                    tags.where((t) => item.tagIds.contains(t.id)).toList();
                return Dismissible(
                  key: ValueKey('${pl.id}_${item.id}_$i'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: Colors.red,
                    child:
                        const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) => _removeItem(pl, item.id),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 64,
                        height: 36,
                        child: _buildThumbnail(item),
                      ),
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: _buildSubtitle(item, itemTags),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const Icon(Icons.drag_handle, color: Colors.grey),
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) =>
                                DetailScreen(itemId: item.id)),
                      );
                    },
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddSheet(pl),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget? _buildSubtitle(LoopItem item, List<Tag> itemTags) {
    final parts = <String>[];
    if (item.pointAMs > 0 || item.pointBMs > 0) {
      parts.add('AB設定あり');
    }
    if (item.speed != 1.0) parts.add('${item.speed}x');

    final widgets = <Widget>[];
    if (parts.isNotEmpty) {
      widgets.add(Text(parts.join(' | '),
          style: const TextStyle(fontSize: 11, color: Colors.grey)));
    }
    if (itemTags.isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Wrap(
          spacing: 3,
          children: itemTags
              .map((t) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(t.name, style: const TextStyle(fontSize: 9)),
                  ))
              .toList(),
        ),
      ));
    }
    if (widgets.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  Widget _buildThumbnail(LoopItem item) {
    if (item.thumbnailPath != null) {
      final file = File(item.thumbnailPath!);
      return Image.file(file, fit: BoxFit.cover, errorBuilder: (_, __, ___) {
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.play_circle_outline,
              color: Colors.grey, size: 18),
        );
      });
    }
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          item.sourceType == 'youtube'
              ? Icons.play_circle_outline
              : Icons.video_file_outlined,
          color: Colors.grey,
          size: 18,
        ),
      ),
    );
  }
}

// ============================================================
// 一覧から選択シート
// ============================================================

class _ItemPickerSheet extends StatefulWidget {
  final List<LoopItem> items;
  final Set<String> existingIds;
  final ScrollController scrollController;
  final void Function(List<String> ids) onAdd;

  const _ItemPickerSheet({
    required this.items,
    required this.existingIds,
    required this.scrollController,
    required this.onAdd,
  });

  @override
  State<_ItemPickerSheet> createState() => _ItemPickerSheetState();
}

class _ItemPickerSheetState extends State<_ItemPickerSheet> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {};
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              const Text('曲を選択',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () {
                        widget.onAdd(_selected.toList());
                        Navigator.pop(context);
                      },
                child: Text('追加 (${_selected.length})'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: widget.scrollController,
            itemCount: widget.items.length,
            itemBuilder: (context, i) {
              final item = widget.items[i];
              final alreadyIn = widget.existingIds.contains(item.id);
              final selected = _selected.contains(item.id);
              return CheckboxListTile(
                value: alreadyIn || selected,
                onChanged: alreadyIn
                    ? null
                    : (_) {
                        setState(() {
                          if (selected) {
                            _selected.remove(item.id);
                          } else {
                            _selected.add(item.id);
                          }
                        });
                      },
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: alreadyIn ? Colors.grey : null,
                  ),
                ),
                subtitle: alreadyIn
                    ? const Text('追加済み',
                        style: TextStyle(fontSize: 11, color: Colors.grey))
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
