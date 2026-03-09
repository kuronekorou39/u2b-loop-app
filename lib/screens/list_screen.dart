import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../providers/data_provider.dart';
import '../providers/theme_provider.dart';
import 'editor_screen.dart';

class ListScreen extends ConsumerStatefulWidget {
  const ListScreen({super.key});

  @override
  ConsumerState<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends ConsumerState<ListScreen>
    with SingleTickerProviderStateMixin {
  bool _isCardView = true;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _openEditor(LoopItem? item) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorScreen(item: item)),
    );
  }

  Future<void> _deleteItem(LoopItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${item.title}」を削除しますか？'),
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
    if (confirmed == true) {
      ref.read(loopItemsProvider.notifier).delete(item.id);
    }
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プレイリスト作成'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'プレイリスト名',
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
            child: const Text('作成'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      ref.read(playlistsProvider.notifier).add(Playlist(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: name,
          ));
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${playlist.name}」を削除しますか？'),
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
    if (confirmed == true) {
      ref.read(playlistsProvider.notifier).delete(playlist.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(loopItemsProvider);
    final playlists = ref.watch(playlistsProvider);
    final isDark = ref.watch(themeProvider);
    final isDataTab = _tabController.index == 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'U2B Loop',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        centerTitle: false,
        actions: [
          if (isDataTab)
            IconButton(
              icon: Icon(_isCardView ? Icons.view_list : Icons.grid_view),
              onPressed: () => setState(() => _isCardView = !_isCardView),
              tooltip: _isCardView ? 'リスト表示' : 'カード表示',
            ),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () {
              ref.read(themeProvider.notifier).state = !isDark;
            },
            tooltip: isDark ? 'ライトテーマ' : 'ダークテーマ',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'ループ'),
            Tab(text: 'プレイリスト'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // --- すべて ---
          items.isEmpty
              ? _buildEmpty(
                  Icons.music_note_outlined, 'データがありません', '＋ ボタンで新規追加')
              : _isCardView
                  ? _buildCardView(items)
                  : _buildListView(items),

          // --- プレイリスト ---
          playlists.isEmpty
              ? _buildEmpty(
                  Icons.playlist_play, 'プレイリストがありません', '＋ ボタンで新規作成')
              : _buildPlaylistList(playlists),
        ],
      ),
      floatingActionButton: isDataTab
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(null),
              icon: const Icon(Icons.add),
              label: const Text('新規追加'),
            )
          : FloatingActionButton.extended(
              onPressed: _createPlaylist,
              icon: const Icon(Icons.playlist_add),
              label: const Text('作成'),
            ),
    );
  }

  Widget _buildEmpty(IconData icon, String title, String sub) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 64,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5))),
          const SizedBox(height: 4),
          Text(sub,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.3))),
        ],
      ),
    );
  }

  // === Card view (grid) ===

  Widget _buildCardView(List<LoopItem> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 16 / 14,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _buildCard(items[i]),
    );
  }

  Widget _buildCard(LoopItem item) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openEditor(item),
        onLongPress: () => _deleteItem(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _buildThumbnail(item),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    if (item.pointAMs > 0 || item.pointBMs > 0)
                      Text(
                        'A ${TimeUtils.formatShort(Duration(milliseconds: item.pointAMs))} '
                        '- B ${TimeUtils.formatShort(Duration(milliseconds: item.pointBMs))}',
                        style:
                            const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    if (item.memo != null && item.memo!.isNotEmpty)
                      Text(
                        item.memo!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // === List view (detailed) ===

  Widget _buildListView(List<LoopItem> items) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      itemBuilder: (context, i) => _buildListTile(items[i]),
    );
  }

  Widget _buildListTile(LoopItem item) {
    return ListTile(
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
      subtitle: _buildSubtitle(item),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'delete') _deleteItem(item);
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'delete', child: Text('削除')),
        ],
      ),
      onTap: () => _openEditor(item),
    );
  }

  Widget? _buildSubtitle(LoopItem item) {
    final lines = <String>[];
    final info = <String>[];
    if (item.pointAMs > 0 || item.pointBMs > 0) {
      info.add(
          'A ${TimeUtils.formatShort(Duration(milliseconds: item.pointAMs))} '
          '- B ${TimeUtils.formatShort(Duration(milliseconds: item.pointBMs))}');
    }
    if (item.speed != 1.0) {
      info.add('${item.speed}x');
    }
    if (info.isNotEmpty) lines.add(info.join('  |  '));
    if (item.memo != null && item.memo!.isNotEmpty) {
      lines.add(item.memo!);
    }
    if (lines.isEmpty) return null;
    return Text(
      lines.join('\n'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: Colors.grey),
    );
  }

  // === Playlist list ===

  Widget _buildPlaylistList(List<Playlist> playlists) {
    final items = ref.watch(loopItemsProvider);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final pl = playlists[i];
        final count = pl.itemIds
            .where((id) => items.any((item) => item.id == id))
            .length;
        return ListTile(
          leading: const Icon(Icons.playlist_play),
          title: Text(pl.name),
          subtitle: Text('$count 曲',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') _deletePlaylist(pl);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'delete', child: Text('削除')),
            ],
          ),
        );
      },
    );
  }

  // === Thumbnail ===

  Widget _buildThumbnail(LoopItem item) {
    if (item.thumbnailPath != null) {
      final file = File(item.thumbnailPath!);
      return Image.file(file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholderThumb(item));
    }
    return _placeholderThumb(item);
  }

  Widget _placeholderThumb(LoopItem item) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          item.sourceType == 'youtube'
              ? Icons.play_circle_outline
              : Icons.video_file_outlined,
          color: Colors.grey,
        ),
      ),
    );
  }
}
