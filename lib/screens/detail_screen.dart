import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import 'editor_screen.dart';
import 'player_screen.dart';

class DetailScreen extends ConsumerStatefulWidget {
  final String itemId;

  const DetailScreen({super.key, required this.itemId});

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _memoController;
  bool _initialized = false;

  void _initControllers(LoopItem item) {
    if (!_initialized) {
      _titleController = TextEditingController(text: item.title);
      _memoController = TextEditingController(text: item.memo ?? '');
      _initialized = true;
    }
  }

  @override
  void dispose() {
    if (_initialized) {
      _titleController.dispose();
      _memoController.dispose();
    }
    super.dispose();
  }

  bool _hasChanges(LoopItem item) {
    if (!_initialized) return false;
    return _titleController.text.trim() != item.title ||
        _memoController.text.trim() != (item.memo ?? '');
  }

  Future<void> _save(LoopItem item) async {
    final title = _titleController.text.trim();
    final memo = _memoController.text.trim();
    if (title.isEmpty) return;

    item.title = title;
    item.memo = memo.isEmpty ? null : memo;
    await ref.read(loopItemsProvider.notifier).update(item);

    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('変更を破棄しますか？'),
        content: const Text('保存していない変更があります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('戻る'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('破棄', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _openPlayer(LoopItem item) {
    if (_hasChanges(item)) _save(item);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(item: item)),
    );
  }

  void _openAbEditor(LoopItem item, {int regionIndex = 0}) {
    if (_hasChanges(item)) {
      // Save without pop
      final title = _titleController.text.trim();
      final memo = _memoController.text.trim();
      if (title.isNotEmpty) {
        item.title = title;
        item.memo = memo.isEmpty ? null : memo;
        ref.read(loopItemsProvider.notifier).update(item);
      }
    }
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) =>
              EditorScreen(item: item, initialRegionIndex: regionIndex)),
    );
  }

  Future<void> _duplicateItem(LoopItem item) async {
    if (_hasChanges(item)) {
      final title = _titleController.text.trim();
      final memo = _memoController.text.trim();
      if (title.isNotEmpty) {
        item.title = title;
        item.memo = memo.isEmpty ? null : memo;
        await ref.read(loopItemsProvider.notifier).update(item);
      }
    }
    final copy =
        await ref.read(loopItemsProvider.notifier).duplicate(item);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('複製しました'), duration: Duration(seconds: 1)),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => DetailScreen(itemId: copy.id)),
      );
    }
  }

  void _showAddToPlaylist(LoopItem item) {
    final playlists = ref.read(playlistsProvider);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('プレイリストに追加',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('プレイリストがありません',
                    style: TextStyle(color: Colors.grey)),
              ),
            for (final pl in playlists)
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: Text(pl.name),
                onTap: () {
                  Navigator.pop(ctx);
                  ref
                      .read(playlistsProvider.notifier)
                      .addItems(pl.id, [item.id]);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('「${pl.name}」に追加しました'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
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
    if (confirmed == true && mounted) {
      ref.read(loopItemsProvider.notifier).delete(item.id);
      Navigator.of(context).pop();
    }
  }

  // --- YouTube URL ---

  String? _getYouTubeUrl(LoopItem item) {
    if (item.youtubeUrl != null && item.youtubeUrl!.isNotEmpty) {
      return item.youtubeUrl;
    }
    if (item.videoId != null) {
      return 'https://youtu.be/${item.videoId}';
    }
    return null;
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('URLをコピーしました'), duration: Duration(seconds: 1)),
    );
  }

  void _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // --- タグ管理 ---

  void _showTagPicker(LoopItem item) {
    final tags = ref.read(tagsProvider);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ItemTagSheet(
        tags: tags,
        item: item,
        onToggle: (tagId, add) async {
          if (add) {
            await ref
                .read(loopItemsProvider.notifier)
                .addTagToItems([item.id], tagId);
          } else {
            await ref
                .read(loopItemsProvider.notifier)
                .removeTagFromItems([item.id], tagId);
          }
        },
        onCreateAndAdd: (name) async {
          final tag = await ref.read(tagsProvider.notifier).create(name);
          await ref
              .read(loopItemsProvider.notifier)
              .addTagToItems([item.id], tag.id);
          return tag;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);
    final item = items.where((e) => e.id == widget.itemId).firstOrNull;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('詳細')),
        body: const Center(child: Text('データが見つかりません')),
      );
    }

    _initControllers(item);

    final ytUrl = _getYouTubeUrl(item);
    final itemTags = tags.where((t) => item.tagIds.contains(t.id)).toList();
    final regions = item.effectiveRegions;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!_hasChanges(item)) {
          Navigator.of(context).pop();
          return;
        }
        if (await _confirmDiscard() && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('詳細', style: TextStyle(fontSize: 16)),
          actions: [
            TextButton.icon(
              onPressed: () => _save(item),
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'duplicate') _duplicateItem(item);
                if (v == 'playlist') _showAddToPlaylist(item);
                if (v == 'delete') _deleteItem(item);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'duplicate', child: Text('複製')),
                const PopupMenuItem(
                    value: 'playlist', child: Text('プレイリストに追加')),
                const PopupMenuItem(
                    value: 'delete',
                    child:
                        Text('削除', style: TextStyle(color: Colors.red))),
              ],
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // サムネイル
              _buildThumbnail(item),
              const SizedBox(height: 16),

              // 再生ボタン
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _openPlayer(item),
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: const Text('再生'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // タイトル
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'タイトル',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),

              // 備考
              TextField(
                controller: _memoController,
                decoration: const InputDecoration(
                  labelText: '備考',
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '練習メモなど',
                ),
                style: const TextStyle(fontSize: 14),
                maxLines: 4,
                minLines: 1,
              ),
              const SizedBox(height: 16),

              // タグ
              _buildTagSection(item, itemTags),
              const SizedBox(height: 12),

              // YouTube URL
              if (ytUrl != null) ...[
                _buildUrlCard(ytUrl),
                const SizedBox(height: 12),
              ],

              // ソース情報
              _buildSourceInfo(item),
              const SizedBox(height: 12),

              // AB区間一覧
              if (regions.isNotEmpty) ...[
                _buildRegionsList(item, regions),
                const SizedBox(height: 12),
              ],

              // AB区間設定ボタン
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openAbEditor(item),
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(
                    regions.isNotEmpty ? 'AB区間を編集' : 'AB区間を設定',
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  // --- Regions list ---

  Widget _buildRegionsList(LoopItem item, List<dynamic> regions) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.segment, size: 18, color: Colors.grey),
                SizedBox(width: 8),
                Text('AB区間',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < regions.length; i++)
              InkWell(
                onTap: () => _openAbEditor(item, regionIndex: i),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  child: Row(
                    children: [
                      Text(
                        regions[i].name,
                        style: const TextStyle(fontSize: 13),
                      ),
                      const Spacer(),
                      Text(
                        '${TimeUtils.formatShort(Duration(milliseconds: regions[i].pointAMs))}',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.pointAColor),
                      ),
                      const Text(' - ',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(
                        '${TimeUtils.formatShort(Duration(milliseconds: regions[i].pointBMs))}',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.pointBColor),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right,
                          size: 16, color: Colors.grey),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- タグセクション ---

  Widget _buildTagSection(LoopItem item, List<Tag> itemTags) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.label_outline, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                const Text('タグ',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const Spacer(),
                SizedBox(
                  height: 28,
                  child: TextButton(
                    onPressed: () => _showTagPicker(item),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8)),
                    child:
                        const Text('編集', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
            if (itemTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: itemTags
                      .map((t) => Chip(
                            label: Text(t.name,
                                style: const TextStyle(fontSize: 12)),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            deleteIcon: const Icon(Icons.close, size: 14),
                            onDeleted: () {
                              ref
                                  .read(loopItemsProvider.notifier)
                                  .removeTagFromItems([item.id], t.id);
                            },
                          ))
                      .toList(),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('タグなし',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }

  // --- YouTube URL ---

  Widget _buildUrlCard(String url) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.link, size: 18, color: Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                url,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => _copyUrl(url),
              tooltip: 'コピー',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: () => _openUrl(url),
              tooltip: '開く',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  // --- Thumbnail ---

  Widget _buildThumbnail(LoopItem item) {
    Widget content;
    if (item.thumbnailPath != null) {
      final file = File(item.thumbnailPath!);
      content = Image.file(file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholderThumb(item));
    } else {
      content = _placeholderThumb(item);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(aspectRatio: 16 / 9, child: content),
    );
  }

  Widget _placeholderThumb(LoopItem item) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            item.sourceType == 'youtube'
                ? Icons.play_circle_outline
                : Icons.video_file_outlined,
            size: 48,
            color: Colors.grey,
          ),
          if (item.sourceType == 'local')
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('ローカルファイル',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceInfo(LoopItem item) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              item.sourceType == 'youtube'
                  ? Icons.smart_display
                  : Icons.folder,
              size: 18,
              color: Colors.grey,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.sourceType == 'youtube'
                    ? 'YouTube (${item.videoId ?? ""})'
                    : item.uri,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 個別アイテムのタグ編集シート
// ============================================================

class _ItemTagSheet extends StatefulWidget {
  final List<Tag> tags;
  final LoopItem item;
  final void Function(String tagId, bool add) onToggle;
  final Future<Tag> Function(String name) onCreateAndAdd;

  const _ItemTagSheet({
    required this.tags,
    required this.item,
    required this.onToggle,
    required this.onCreateAndAdd,
  });

  @override
  State<_ItemTagSheet> createState() => _ItemTagSheetState();
}

class _ItemTagSheetState extends State<_ItemTagSheet> {
  late Set<String> _activeTagIds;
  late List<Tag> _tags;

  @override
  void initState() {
    super.initState();
    _activeTagIds = Set.from(widget.item.tagIds);
    _tags = List.from(widget.tags);
  }

  void _toggle(String tagId) {
    setState(() {
      if (_activeTagIds.contains(tagId)) {
        _activeTagIds.remove(tagId);
        widget.onToggle(tagId, false);
      } else {
        _activeTagIds.add(tagId);
        widget.onToggle(tagId, true);
      }
    });
  }

  void _createNew() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新しいタグ'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'タグ名',
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
            child: const Text('作成して追加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      final tag = await widget.onCreateAndAdd(name);
      setState(() {
        _tags.add(tag);
        _activeTagIds.add(tag.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('タグを選択',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            if (_tags.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('タグがありません',
                    style: TextStyle(color: Colors.grey)),
              ),
            for (final tag in _tags)
              CheckboxListTile(
                title: Text(tag.name, style: const TextStyle(fontSize: 14)),
                value: _activeTagIds.contains(tag.id),
                onChanged: (_) => _toggle(tag.id),
              ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: OutlinedButton.icon(
                onPressed: _createNew,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新しいタグを作成して追加'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
