import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import '../widgets/item_tag_sheet.dart';
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
              child: Text('プレイリストに追加',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('プレイリストがありません',
                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: Colors.grey)),
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
      builder: (ctx) => ItemTagSheet(
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
    final textTheme = Theme.of(context).textTheme;

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
        if (await _confirmDiscard()) {
          if (!context.mounted) return;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('詳細', style: textTheme.displaySmall),
          actions: [
            if (_hasChanges(item))
              TextButton.icon(
                onPressed: () => _save(item),
                icon: const Icon(Icons.save, size: AppIconSizes.sm),
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
              const SizedBox(height: AppSpacing.xl),

              // 再生ボタン
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _openPlayer(item),
                  icon: const Icon(Icons.play_arrow, size: AppIconSizes.md),
                  label: const Text('再生'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // タイトル
              TextField(
                controller: _titleController,
                maxLength: AppLimits.titleMaxLength,
                decoration: const InputDecoration(
                  labelText: 'タイトル',
                  isDense: true,
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.lg),

              // 備考
              TextField(
                controller: _memoController,
                maxLength: AppLimits.memoMaxLength,
                decoration: const InputDecoration(
                  labelText: '備考',
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '練習メモなど',
                  counterText: '',
                ),
                style: textTheme.bodySmall,
                maxLines: 4,
                minLines: 1,
              ),
              const SizedBox(height: AppSpacing.xl),

              // タグ
              _buildTagSection(item, itemTags),
              const SizedBox(height: AppSpacing.lg),

              // 再生回数
              if (item.playCount > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                  child: Row(
                    children: [
                      Icon(Icons.headphones, size: AppIconSizes.sm,
                          color: textTheme.bodySmall!.color),
                      const SizedBox(width: AppSpacing.xs),
                      Text('${item.playCount}回再生',
                          style: textTheme.bodySmall),
                    ],
                  ),
                ),

              // YouTube URL
              if (ytUrl != null) ...[
                _buildUrlCard(ytUrl),
                const SizedBox(height: AppSpacing.lg),
              ],

              // ソース情報 (hide videoId for YouTube)
              if (item.sourceType != 'youtube')
                _buildSourceInfo(item),
              if (item.sourceType != 'youtube')
                const SizedBox(height: AppSpacing.lg),

              // AB区間一覧
              if (regions.isNotEmpty) ...[
                _buildRegionsList(item, regions),
                const SizedBox(height: AppSpacing.lg),
              ],

              // AB区間設定ボタン
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openAbEditor(item),
                  icon: const Icon(Icons.tune, size: AppIconSizes.sm),
                  label: Text(
                    regions.isNotEmpty ? 'AB区間を編集' : 'AB区間を設定',
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),

              SizedBox(height: MediaQuery.of(context).viewPadding.bottom + 48),
            ],
          ),
        ),
      ),
    );
  }

  // --- Regions list ---

  Widget _buildRegionsList(LoopItem item, List<dynamic> regions) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.segment, size: AppIconSizes.sm, color: Colors.grey),
        title: Text('AB区間 (${regions.length})',
            style: textTheme.bodyMedium!.copyWith(color: Colors.grey)),
        initiallyExpanded: false,
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        childrenPadding:
            const EdgeInsets.only(left: AppSpacing.lg, right: AppSpacing.lg, bottom: AppSpacing.md),
        children: [
          for (var i = 0; i < regions.length; i++)
            InkWell(
              onLongPress: () => _showRegionEditMenu(item, i),
              borderRadius: AppRadius.borderXs,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.xs),
                child: Row(
                  children: [
                    Text(
                      regions[i].name,
                      style: textTheme.bodyMedium,
                    ),
                    const Spacer(),
                    Text(
                      regions[i].hasA
                          ? TimeUtils.formatShort(Duration(
                              milliseconds: regions[i].pointAMs!))
                          : '--:--',
                      style: textTheme.labelMedium!.copyWith(
                          color: AppTheme.pointAColor),
                    ),
                    Text(' - ',
                        style: textTheme.labelMedium!.copyWith(
                            color: Colors.grey)),
                    Text(
                      regions[i].hasB
                          ? TimeUtils.formatShort(Duration(
                              milliseconds: regions[i].pointBMs!))
                          : '--:--',
                      style: textTheme.labelMedium!.copyWith(
                          color: AppTheme.pointBColor),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Icon(Icons.more_vert, size: AppIconSizes.xs,
                        color: Colors.grey[700]),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showRegionEditMenu(LoopItem item, int index) {
    final region = item.effectiveRegions[index];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('名前を変更'),
              onTap: () {
                Navigator.pop(ctx);
                _renameRegion(item, index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer),
              title: Text(
                'A: ${region.hasA ? TimeUtils.formatShort(Duration(milliseconds: region.pointAMs!)) : "--:--"}'
                '  B: ${region.hasB ? TimeUtils.formatShort(Duration(milliseconds: region.pointBMs!)) : "--:--"}',
              ),
              subtitle: const Text('AB時間を編集'),
              onTap: () {
                Navigator.pop(ctx);
                _editRegionTimes(item, index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('削除',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteRegion(item, index);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _renameRegion(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    final controller = TextEditingController(text: regions[index].name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('区間名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.regionNameMaxLength,
          decoration: const InputDecoration(
            hintText: '区間名を入力',
            isDense: true,
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;

    regions[index] = regions[index].copyWith(name: name);
    item.regions = List.from(regions);
    if (regions.isNotEmpty) {
      item.pointAMs = regions.first.pointAMs ?? 0;
      item.pointBMs = regions.first.pointBMs ?? 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  void _editRegionTimes(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    final region = regions[index];
    final aController = TextEditingController(
        text: region.hasA ? (region.pointAMs! / 1000).toStringAsFixed(1) : '');
    final bController = TextEditingController(
        text: region.hasB ? (region.pointBMs! / 1000).toStringAsFixed(1) : '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${region.name} のAB時間'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aController,
              decoration: const InputDecoration(
                labelText: 'A (秒)',
                hintText: '例: 10.5',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bController,
              decoration: const InputDecoration(
                labelText: 'B (秒)',
                hintText: '例: 45.0',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    aController.dispose();
    bController.dispose();
    if (result != true) return;

    final aText = aController.text.trim();
    final bText = bController.text.trim();
    final aParsed = aText.isNotEmpty ? double.tryParse(aText) : null;
    final bParsed = bText.isNotEmpty ? double.tryParse(bText) : null;
    final aMs = aParsed != null ? (aParsed * 1000).round() : null;
    final bMs = bParsed != null ? (bParsed * 1000).round() : null;

    regions[index] = regions[index].copyWith(
      pointAMs: () => aMs,
      pointBMs: () => bMs,
    );
    item.regions = List.from(regions);
    if (regions.isNotEmpty) {
      item.pointAMs = regions.first.pointAMs ?? 0;
      item.pointBMs = regions.first.pointBMs ?? 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  void _deleteRegion(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    regions.removeAt(index);
    item.regions = List.from(regions);
    if (regions.isNotEmpty) {
      item.pointAMs = regions.first.pointAMs ?? 0;
      item.pointBMs = regions.first.pointBMs ?? 0;
    } else {
      item.pointAMs = 0;
      item.pointBMs = 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  // --- タグセクション ---

  Widget _buildTagSection(LoopItem item, List<Tag> itemTags) {
    final textTheme = Theme.of(context).textTheme;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        ...itemTags.map((t) => Chip(
              avatar: t.color != null
                  ? Icon(Icons.circle, size: 10, color: t.color)
                  : null,
              label: Text(t.name, style: textTheme.labelMedium),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              deleteIcon: const Icon(Icons.close, size: AppIconSizes.xs),
              onDeleted: () {
                ref
                    .read(loopItemsProvider.notifier)
                    .removeTagFromItems([item.id], t.id);
              },
            )),
        OutlinedButton.icon(
          onPressed: () => _showTagPicker(item),
          icon: const Icon(Icons.add, size: AppIconSizes.s),
          label: Text(
            itemTags.isEmpty ? 'タグ追加' : '追加',
            style: textTheme.labelMedium,
          ),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
            side: BorderSide(color: Colors.grey.shade700),
          ),
        ),
      ],
    );
  }

  // --- YouTube URL ---

  Widget _buildUrlCard(String url) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            const Icon(Icons.link, size: AppIconSizes.sm, color: Colors.grey),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                url,
                style: textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: AppIconSizes.sm),
              onPressed: () => _copyUrl(url),
              tooltip: 'コピー',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.open_in_new, size: AppIconSizes.sm),
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
          errorBuilder: (_, _, _) => _placeholderThumb(item));
    } else {
      content = _placeholderThumb(item);
    }
    return Hero(
      tag: 'thumb_${item.id}',
      child: ClipRRect(
        borderRadius: AppRadius.borderMd,
        child: AspectRatio(aspectRatio: 16 / 9, child: content),
      ),
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
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Icon(
              item.sourceType == 'youtube'
                  ? Icons.smart_display
                  : Icons.folder,
              size: AppIconSizes.sm,
              color: Colors.grey,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                item.sourceType == 'youtube'
                    ? 'YouTube (${item.videoId ?? ""})'
                    : item.uri,
                style: Theme.of(context).textTheme.bodySmall,
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

// タグ編集シートは ItemTagSheet (widgets/item_tag_sheet.dart) に移動
