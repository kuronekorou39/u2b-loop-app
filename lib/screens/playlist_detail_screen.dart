import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/loop_region.dart';
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

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ItemPickerPage(
          items: readyItems,
          existingIds: existing,
          existingRegions: pl.regionSelections,
          onAdd: (ids, regions) {
            ref
                .read(playlistsProvider.notifier)
                .addItems(pl.id, ids, regions: regions);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${ids.length}件を追加しました'),
                duration: const Duration(seconds: 2),
              ),
            );
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
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlayerScreen(
                      item: items.first,
                      playlistItems: items,
                      regionSelections: pl.regionSelections.isNotEmpty
                          ? pl.regionSelections
                          : null,
                      disabledItemIds: pl.disabledItemIds.isNotEmpty
                          ? pl.disabledItemIds
                          : null,
                      playlistName: pl.name,
                      playlistId: pl.id,
                    ),
                  ),
                ),
                icon: const Icon(Icons.play_arrow, size: 20),
                label: const Text('再生', style: TextStyle(fontSize: 13)),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                ),
              ),
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
              padding: EdgeInsets.only(
                  bottom: 80 + MediaQuery.of(context).viewPadding.bottom),
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
                final isDisabled = pl.disabledItemIds.contains(item.id);
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
                  child: Opacity(
                    opacity: isDisabled ? 0.4 : 1.0,
                    child: ListTile(
                      leading: GestureDetector(
                        onTap: () => ref
                            .read(playlistsProvider.notifier)
                            .toggleItemEnabled(pl.id, item.id),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(
                                width: 64,
                                height: 36,
                                child: _buildThumbnail(item),
                              ),
                            ),
                            if (isDisabled)
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius:
                                        BorderRadius.circular(4),
                                  ),
                                  child: const Icon(Icons.block,
                                      color: Colors.white54, size: 20),
                                ),
                              ),
                          ],
                        ),
                      ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          decoration: isDisabled
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      subtitle: _buildSubtitle(item, itemTags, pl),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Icon(Icons.drag_handle,
                            color: Colors.grey),
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  DetailScreen(itemId: item.id)),
                        );
                      },
                      onLongPress: _hasItemRegions(item)
                          ? () => _showRegionEditSheet(pl, item)
                          : null,
                    ),
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

  /// 「全体」を表す特殊ID（区間選択で全体再生を選ぶ用）
  static const _fullTrackId = '__full__';

  bool _hasItemRegions(LoopItem item) {
    final regions = item.effectiveRegions;
    return regions.isNotEmpty;
  }

  Widget? _buildSubtitle(LoopItem item, List<Tag> itemTags, Playlist pl) {
    final parts = <String>[];

    // 区間選択情報（「全体」も1区間としてカウント）
    if (_hasItemRegions(item)) {
      final allRegions = item.effectiveRegions;
      final totalCount = allRegions.length + 1; // +1 for 全体
      final sel = pl.regionSelections[item.id];
      if (sel != null && sel.isEmpty) {
        parts.add('0/$totalCount 区間（スキップ）');
      } else if (sel != null && sel.isNotEmpty) {
        parts.add('${sel.length}/$totalCount 区間');
      } else {
        // 未設定 = 全区間（全体は含まない）
        parts.add('${allRegions.length}/$totalCount 区間');
      }
    } else if (item.pointAMs > 0 || item.pointBMs > 0) {
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
    if (_hasItemRegions(item)) {
      widgets.add(
        GestureDetector(
          onTap: () => _showRegionEditSheet(pl, item),
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune, size: 12,
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: 0.6)),
                const SizedBox(width: 3),
                Text('区間を選択',
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.primary
                            .withValues(alpha: 0.6))),
              ],
            ),
          ),
        ),
      );
    }
    if (widgets.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  void _showRegionEditSheet(Playlist pl, LoopItem item) {
    final regions = item.effectiveRegions;
    final currentSel = pl.regionSelections[item.id];
    // 未設定なら全区間選択状態（全体は含まない）
    final selected = currentSel != null && currentSel.isNotEmpty
        ? Set<String>.from(currentSel)
        : regions.map((r) => r.id).toSet();

    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('区間を選択',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                    ),
                    TextButton(
                      onPressed: () {
                        ref
                            .read(playlistsProvider.notifier)
                            .updateRegionSelection(
                                pl.id, item.id, selected.toList());
                        Navigator.pop(ctx);
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ),
              // 「全体」オプション
              CheckboxListTile(
                value: selected.contains(_fullTrackId),
                onChanged: (v) {
                  setSheetState(() {
                    if (v == true) {
                      selected.add(_fullTrackId);
                    } else {
                      selected.remove(_fullTrackId);
                    }
                  });
                },
                title: const Text('全体',
                    style: TextStyle(fontSize: 14)),
                subtitle: const Text('区間を使わず全体を再生',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const Divider(height: 1),
              // 各区間
              for (final region in regions)
                CheckboxListTile(
                  value: selected.contains(region.id),
                  onChanged: (v) {
                    setSheetState(() {
                      if (v == true) {
                        selected.add(region.id);
                      } else {
                        selected.remove(region.id);
                      }
                    });
                  },
                  title: Text(region.name,
                      style: const TextStyle(fontSize: 14)),
                  subtitle: region.hasPoints
                      ? Text(
                          '${region.pointAMs != null ? TimeUtils.formatShort(Duration(milliseconds: region.pointAMs!)) : '--:--'}'
                          ' - '
                          '${region.pointBMs != null ? TimeUtils.formatShort(Duration(milliseconds: region.pointBMs!)) : '--:--'}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey))
                      : null,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
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
// 一覧から選択ページ（区間選択対応）
// ============================================================

class _ItemPickerPage extends StatefulWidget {
  final List<LoopItem> items;
  final Set<String> existingIds;
  final Map<String, List<String>> existingRegions;
  final void Function(List<String> ids, Map<String, List<String>> regions)
      onAdd;

  const _ItemPickerPage({
    required this.items,
    required this.existingIds,
    required this.existingRegions,
    required this.onAdd,
  });

  @override
  State<_ItemPickerPage> createState() => _ItemPickerPageState();
}

class _ItemPickerPageState extends State<_ItemPickerPage> {
  // itemId → 選択された regionId の Set
  // マップに存在 = アイテム選択済み
  // Set が空 = 区間なしアイテム、または全区間選択
  final Map<String, Set<String>> _selections = {};
  // 展開中のアイテムID
  final Set<String> _expanded = {};
  String _searchQuery = '';

  int get _selectedCount => _selections.length;

  static const _fullTrackId = _PlaylistDetailScreenState._fullTrackId;

  bool _hasRegions(LoopItem item) {
    return item.effectiveRegions.isNotEmpty;
  }

  void _toggleItem(LoopItem item) {
    setState(() {
      if (_selections.containsKey(item.id)) {
        _selections.remove(item.id);
        _expanded.remove(item.id);
      } else {
        if (_hasRegions(item)) {
          // 区間付き: 全区間を選択して展開（全体は含まない）
          _selections[item.id] = item.effectiveRegions.map((r) => r.id).toSet();
          _expanded.add(item.id);
        } else {
          _selections[item.id] = {};
        }
      }
    });
  }

  void _toggleRegion(LoopItem item, String regionId) {
    setState(() {
      final sel = _selections[item.id];
      if (sel == null) return;
      if (sel.contains(regionId)) {
        sel.remove(regionId);
        // 全区間が外されたらアイテム自体を解除
        if (sel.isEmpty) {
          _selections.remove(item.id);
          _expanded.remove(item.id);
        }
      } else {
        sel.add(regionId);
      }
    });
  }

  void _submit() {
    final ids = <String>[];
    final regions = <String, List<String>>{};

    for (final entry in _selections.entries) {
      ids.add(entry.key);
      if (entry.value.isNotEmpty) {
        regions[entry.key] = entry.value.toList();
      }
    }

    widget.onAdd(ids, regions);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    var items = widget.items;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      items = items.where((i) => i.title.toLowerCase().contains(q)).toList();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('曲を選択', style: TextStyle(fontSize: 16)),
        actions: [
          FilledButton(
            onPressed: _selectedCount == 0 ? null : _submit,
            child: Text('追加 ($_selectedCount)'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SizedBox(
              height: 36,
              child: TextField(
                decoration: InputDecoration(
                  hintText: '検索...',
                  hintStyle: const TextStyle(fontSize: 13),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: Colors.grey.shade700),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: Colors.grey.shade700),
                  ),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => _buildItemTile(items[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemTile(LoopItem item) {
    final alreadyIn = widget.existingIds.contains(item.id);
    final isSelected = _selections.containsKey(item.id);
    final hasRegions = _hasRegions(item);
    final isExpanded = _expanded.contains(item.id);
    final regions = item.effectiveRegions;
    final selectedRegions = _selections[item.id];

    // Checkbox state: tristate for partial region selection
    bool? checkValue;
    if (alreadyIn) {
      checkValue = true;
    } else if (!isSelected) {
      checkValue = false;
    } else if (hasRegions && selectedRegions != null) {
      checkValue =
          selectedRegions.length == regions.length ? true : null;
    } else {
      checkValue = true;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
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
            style: TextStyle(
              fontSize: 14,
              color: alreadyIn ? Colors.grey : null,
            ),
          ),
          subtitle: alreadyIn
              ? const Text('追加済み',
                  style: TextStyle(fontSize: 11, color: Colors.grey))
              : hasRegions
                  ? Text(
                      '${regions.length + 1} 区間（全体含む）',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
                    )
                  : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasRegions && !alreadyIn)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isExpanded) {
                        _expanded.remove(item.id);
                      } else {
                        _expanded.add(item.id);
                      }
                    });
                  },
                  child: Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 24,
                    color: Colors.grey,
                  ),
                ),
              Checkbox(
                value: checkValue,
                tristate: true,
                onChanged: alreadyIn ? null : (_) => _toggleItem(item),
              ),
            ],
          ),
          onTap: alreadyIn ? null : () => _toggleItem(item),
        ),
        // Region sub-list (with 全体 option)
        if (isExpanded && hasRegions && !alreadyIn) ...[
          // 「全体」オプション
          Padding(
            padding: const EdgeInsets.only(left: 80),
            child: ListTile(
              dense: true,
              visualDensity: const VisualDensity(vertical: -3),
              title: const Text('全体',
                  style: TextStyle(fontSize: 13)),
              subtitle: const Text('区間を使わず全体を再生',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              trailing: Checkbox(
                value: selectedRegions?.contains(_fullTrackId) ?? false,
                onChanged: isSelected
                    ? (_) => _toggleRegion(item, _fullTrackId)
                    : null,
                visualDensity: VisualDensity.compact,
              ),
              onTap: isSelected
                  ? () => _toggleRegion(item, _fullTrackId)
                  : null,
            ),
          ),
          ...regions.map((region) {
            final regionSelected =
                selectedRegions?.contains(region.id) ?? false;
            final timeStr = _formatRegionTime(region);
            return Padding(
              padding: const EdgeInsets.only(left: 80),
              child: ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -3),
                title: Text(
                  region.name,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: timeStr != null
                    ? Text(timeStr,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey))
                    : null,
                trailing: Checkbox(
                  value: regionSelected,
                  onChanged: isSelected
                      ? (_) => _toggleRegion(item, region.id)
                      : null,
                  visualDensity: VisualDensity.compact,
                ),
                onTap: isSelected
                    ? () => _toggleRegion(item, region.id)
                    : null,
              ),
            );
          }),
        ],
      ],
    );
  }

  String? _formatRegionTime(LoopRegion region) {
    if (!region.hasPoints) return null;
    final a = region.pointAMs != null
        ? TimeUtils.formatShort(Duration(milliseconds: region.pointAMs!))
        : '--:--';
    final b = region.pointBMs != null
        ? TimeUtils.formatShort(Duration(milliseconds: region.pointBMs!))
        : '--:--';
    return '$a - $b';
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
