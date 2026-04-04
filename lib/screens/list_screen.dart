import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../core/utils/url_utils.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';

import 'detail_screen.dart';
import 'playlist_detail_screen.dart';
import 'settings_screen.dart';

/// 表示モード: リスト / 2列 / 4列
enum _ViewMode { list, grid2, grid4 }

enum _SortMode { updatedDesc, updatedAsc, titleAsc, titleDesc, createdDesc }

class ListScreen extends ConsumerStatefulWidget {
  const ListScreen({super.key});

  @override
  ConsumerState<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends ConsumerState<ListScreen>
    with SingleTickerProviderStateMixin {
  _ViewMode _viewMode = _ViewMode.grid2;
  late final TabController _tabController;

  // 複数選択
  final Set<String> _selectedIds = {};
  bool get _isSelecting => _selectedIds.isNotEmpty;

  String _searchQuery = '';
  _SortMode _sortMode = _SortMode.updatedDesc;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // --- 追加ダイアログ ---

  void _showAddDialog() {
    final urlController = TextEditingController();

    void doAdd(BuildContext dialogCtx) async {
      final url = urlController.text.trim();
      if (url.isEmpty) return;

      final videoId = UrlUtils.extractVideoId(url);
      final playlistId = UrlUtils.extractPlaylistId(url);

      // プレイリストURLのみ（動画IDなし）→ プレイリストインポート
      if (videoId == null && playlistId != null) {
        Navigator.pop(dialogCtx);
        _importPlaylist(playlistId);
        return;
      }

      // 動画ID + プレイリストID → 選択肢を提示
      if (videoId != null && playlistId != null) {
        Navigator.pop(dialogCtx);
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('どちらを追加しますか？',
                style: TextStyle(fontSize: 15)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'video'),
                child: const Text('この動画のみ'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'playlist'),
                child: const Text('プレイリスト全体'),
              ),
            ],
          ),
        );
        if (!mounted || choice == null) return;
        if (choice == 'playlist') {
          _importPlaylist(playlistId);
        } else {
          ref
              .read(loopItemsProvider.notifier)
              .addYouTubeAndFetch(videoId, url);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('追加しました（情報を取得中...）'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      if (videoId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('無効なYouTube URLです')),
        );
        return;
      }
      ref.read(loopItemsProvider.notifier).addYouTubeAndFetch(videoId, url);
      Navigator.pop(dialogCtx);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('追加しました（情報を取得中...）'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('追加', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              autofocus: true,
              maxLength: AppLimits.urlMaxLength,
              decoration: const InputDecoration(
                hintText: 'YouTube URL / プレイリストURL',
                hintStyle: kHintStyle,
                prefixIcon: Icon(Icons.link, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
                counterText: '',
              ),
              style: const TextStyle(fontSize: 13),
              maxLines: 3,
              minLines: 3,
              onSubmitted: (_) => doAdd(ctx),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                onPressed: () => doAdd(ctx),
                icon: const Icon(Icons.play_circle_fill),
                iconSize: 40,
                color: Theme.of(context).colorScheme.primary,
                tooltip: '追加',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('または',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.4))),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _addLocalFile();
                },
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('ローカルファイルを選択'),
              ),
            ),
          ],
        ),
      ),
    ).then((_) => urlController.dispose());
  }

  Future<void> _addLocalFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    if (path == null) return;
    ref.read(loopItemsProvider.notifier).addLocalFile(path, file.name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('追加しました'), duration: Duration(seconds: 2)),
      );
    }
  }

  // --- YouTubeプレイリストインポート ---

  bool _importCancelled = false;

  Future<void> _importPlaylist(String playlistId) async {
    if (!mounted) return;
    _importCancelled = false;

    // 進捗付きダイアログ（キャンセル可能）
    final countNotifier = ValueNotifier<int>(0);
    final statusNotifier = ValueNotifier<String>('プレイリスト情報を取得中...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<String>(
          valueListenable: statusNotifier,
          builder: (_, status, __) => ValueListenableBuilder<int>(
            valueListenable: countNotifier,
            builder: (_, count, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: Text(status, style: const TextStyle(fontSize: 14))),
                  ],
                ),
                if (count > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('$count 件取得済み',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _importCancelled = true;
              Navigator.pop(context);
            },
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );

    try {
      final yt = yte.YoutubeExplode();
      try {
        statusNotifier.value = 'プレイリスト情報を取得中...';
        final playlist = await yt.playlists.get(playlistId);
        if (_importCancelled) return;

        statusNotifier.value = '「${playlist.title}」の動画を取得中...';
        final videos = <yte.Video>[];
        await for (final v in yt.playlists.getVideos(playlistId)) {
          if (_importCancelled) break;
          videos.add(v);
          countNotifier.value = videos.length;

          // 100件ごとに5秒休憩（APIページ境界付近）
          if (videos.length % 100 == 0) {
            statusNotifier.value = '${videos.length}件取得済み、少し待機中...';
            await Future.delayed(const Duration(seconds: 5));
          }
        }

        if (_importCancelled || !mounted) return;
        Navigator.pop(context);

        if (videos.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(playlistId.startsWith('RD')
                  ? 'ミックスリストの取得に失敗しました（YouTube側の制限の可能性）'
                  : 'プレイリストに動画がありません'),
              duration: const Duration(seconds: 3),
            ),
          );
          return;
        }

        // 既存アイテムとの重複チェック
        final existingItems = ref.read(loopItemsProvider);
        final existingVideoIds =
            existingItems.map((i) => i.videoId).whereType<String>().toSet();
        final duplicates =
            videos.where((v) => existingVideoIds.contains(v.id.value)).toList();
        final newVideos =
            videos.where((v) => !existingVideoIds.contains(v.id.value)).toList();

        if (duplicates.isEmpty) {
          _addVideos(videos, playlist.title);
        } else {
          await _showDuplicateDialog(
            playlistTitle: playlist.title,
            allVideos: videos,
            newVideos: newVideos,
            duplicates: duplicates,
          );
        }
      } finally {
        yt.close();
        countNotifier.dispose();
        statusNotifier.dispose();
      }
    } catch (e) {
      if (_importCancelled) return;
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('取得失敗: $e')),
        );
      }
    }
  }

  Future<void> _addVideos(List<yte.Video> videos, String playlistTitle) async {
    // タグを選択/作成するダイアログ
    final tagId = await _showImportTagDialog(playlistTitle);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('「$playlistTitle」から${videos.length}件を追加中...'),
        duration: const Duration(seconds: 3),
      ),
    );

    final notifier = ref.read(loopItemsProvider.notifier);
    for (final v in videos) {
      await notifier.addYouTubeWithInfo(
        videoId: v.id.value,
        title: v.title,
        originalUrl: 'https://youtu.be/${v.id.value}',
        thumbnailUrl: v.thumbnails.highResUrl,
        tagId: tagId,
      );
    }
  }

  /// インポート時にタグを付与するか選択するダイアログ
  Future<String?> _showImportTagDialog(String playlistTitle) async {
    final tags = ref.read(tagsProvider);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('タグを付与', style: TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('追加する曲に共通のタグを付けますか？',
                style: TextStyle(fontSize: 13, color: Colors.grey[400])),
            const SizedBox(height: 12),
            // 既存タグ
            if (tags.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in tags)
                    ActionChip(
                      label: Text(tag.name,
                          style: const TextStyle(fontSize: 12)),
                      onPressed: () => Navigator.pop(ctx, tag.id),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            const SizedBox(height: 8),
            // プレイリスト名で新規作成
            OutlinedButton.icon(
              onPressed: () async {
                final tag = await ref
                    .read(tagsProvider.notifier)
                    .create(playlistTitle);
                if (ctx.mounted) Navigator.pop(ctx, tag.id);
              },
              icon: const Icon(Icons.add, size: 16),
              label: Text('「$playlistTitle」タグを作成',
                  style: const TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.grey.shade700),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('スキップ'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDuplicateDialog({
    required String playlistTitle,
    required List<yte.Video> allVideos,
    required List<yte.Video> newVideos,
    required List<yte.Video> duplicates,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$playlistTitle (${allVideos.length}件)',
            style: const TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${duplicates.length}件が既に登録されています。',
              style: const TextStyle(fontSize: 13),
            ),
            if (newVideos.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '新規: ${newVideos.length}件',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('キャンセル'),
          ),
          if (newVideos.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              child: Text('新規のみ追加 (${newVideos.length}件)'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: Text('すべて追加 (${allVideos.length}件)'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'select'),
            child: const Text('個別に選択'),
          ),
        ],
      ),
    );
    if (!mounted || result == null || result == 'cancel') return;

    if (result == 'skip') {
      _addVideos(newVideos, playlistTitle);
    } else if (result == 'all') {
      _addVideos(allVideos, playlistTitle);
    } else if (result == 'select') {
      _showVideoSelectPage(allVideos, duplicates, playlistTitle);
    }
  }

  void _showVideoSelectPage(
    List<yte.Video> allVideos,
    List<yte.Video> duplicates,
    String playlistTitle,
  ) {
    final duplicateIds = duplicates.map((v) => v.id.value).toSet();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PlaylistVideoSelectPage(
          videos: allVideos,
          duplicateIds: duplicateIds,
          playlistTitle: playlistTitle,
          onConfirm: (selected) {
            _addVideos(selected, playlistTitle);
          },
        ),
      ),
    );
  }

  // --- アイテム操作 ---

  void _openDetail(LoopItem item) {
    if (_isSelecting) {
      _toggleSelect(item);
      return;
    }
    if (item.isFetching) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('データ取得中です...')),
      );
      return;
    }
    if (item.hasError) {
      _showErrorOptions(item);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen(itemId: item.id)),
    );
  }

  void _showErrorOptions(LoopItem item) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('再試行'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(loopItemsProvider.notifier).retryFetch(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('削除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(loopItemsProvider.notifier).delete(item.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- 複数選択 ---

  void _toggleSelect(LoopItem item) {
    setState(() {
      if (_selectedIds.contains(item.id)) {
        _selectedIds.remove(item.id);
      } else {
        _selectedIds.add(item.id);
      }
    });
  }

  void _startSelect(LoopItem item) {
    setState(() => _selectedIds.add(item.id));
  }

  void _selectAll(List<LoopItem> items) {
    setState(() {
      for (final item in items) {
        _selectedIds.add(item.id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('選択した $count 件を削除しますか？'),
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
      final ids = Set<String>.from(_selectedIds);
      _clearSelection();
      for (final id in ids) {
        await ref.read(loopItemsProvider.notifier).delete(id);
      }
    }
  }

  // --- 複数選択タグ操作 ---

  void _showBulkTagSheet() {
    final tags = ref.read(tagsProvider);
    final items = ref.read(loopItemsProvider);
    final selectedItems =
        items.where((i) => _selectedIds.contains(i.id)).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _BulkTagSheet(
        tags: tags,
        selectedItems: selectedItems,
        onAddTag: (tagId) {
          ref
              .read(loopItemsProvider.notifier)
              .addTagToItems(_selectedIds.toList(), tagId);
        },
        onRemoveTag: (tagId) {
          ref
              .read(loopItemsProvider.notifier)
              .removeTagFromItems(_selectedIds.toList(), tagId);
        },
        onClearTags: () {
          ref
              .read(loopItemsProvider.notifier)
              .clearTagsFromItems(_selectedIds.toList());
        },
        onCreateTag: (name) async {
          final tag = await ref.read(tagsProvider.notifier).create(name);
          return tag;
        },
      ),
    );
  }

  // --- 複数選択 → プレイリストに追加 ---

  void _showAddToPlaylistSheet() {
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
                  final ids = _selectedIds.toList();
                  ref
                      .read(playlistsProvider.notifier)
                      .addItems(pl.id, ids);
                  _clearSelection();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          '${ids.length}件を「${pl.name}」に追加しました'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新規作成して追加'),
              onTap: () async {
                Navigator.pop(ctx);
                final controller = TextEditingController();
                final name = await showDialog<String>(
                  context: context,
                  builder: (dlgCtx) => AlertDialog(
                    title: const Text('プレイリスト作成'),
                    content: TextField(
                      controller: controller,
                      autofocus: true,
                      maxLength: AppLimits.playlistNameMaxLength,
                      decoration: const InputDecoration(
                        hintText: 'プレイリスト名',
                        hintStyle: kHintStyle,
                        isDense: true,
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onSubmitted: (v) => Navigator.pop(dlgCtx, v.trim()),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dlgCtx),
                        child: const Text('キャンセル'),
                      ),
                      TextButton(
                        onPressed: () =>
                            Navigator.pop(dlgCtx, controller.text.trim()),
                        child: const Text('作成'),
                      ),
                    ],
                  ),
                );
                controller.dispose();
                if (name != null && name.isNotEmpty) {
                  final pl = Playlist(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: name,
                  );
                  await ref.read(playlistsProvider.notifier).add(pl);
                  final ids = _selectedIds.toList();
                  await ref
                      .read(playlistsProvider.notifier)
                      .addItems(pl.id, ids);
                  _clearSelection();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content:
                            Text('${ids.length}件を「${pl.name}」に追加しました'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- 表示切替 ---

  void _cycleViewMode() {
    setState(() {
      _viewMode = switch (_viewMode) {
        _ViewMode.list => _ViewMode.grid2,
        _ViewMode.grid2 => _ViewMode.grid4,
        _ViewMode.grid4 => _ViewMode.list,
      };
    });
  }

  IconData get _viewModeIcon => switch (_viewMode) {
        _ViewMode.list => Icons.view_list,
        _ViewMode.grid2 => Icons.grid_view,
        _ViewMode.grid4 => Icons.apps,
      };

  String get _viewModeTooltip => switch (_viewMode) {
        _ViewMode.list => '2列表示へ',
        _ViewMode.grid2 => '4列表示へ',
        _ViewMode.grid4 => 'リスト表示へ',
      };

  // --- タグ管理 ---

  void _showTagManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TagManagerSheet(
        tags: ref.read(tagsProvider),
        onRename: (id, name) {
          ref.read(tagsProvider.notifier).rename(id, name);
        },
        onDelete: (id) async {
          await ref.read(tagsProvider.notifier).delete(id);
          await ref.read(loopItemsProvider.notifier).removeTagFromAll(id);
          // フィルターからも除去
          ref.read(tagFilterProvider.notifier).update((s) => s..remove(id));
        },
        onCreate: (name) {
          ref.read(tagsProvider.notifier).create(name);
        },
      ),
    );
  }

  // --- プレイリスト ---

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

  // === Build ===

  @override
  Widget build(BuildContext context) {
    final allItems = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);
    final filterTagIds = ref.watch(tagFilterProvider);
    final playlists = ref.watch(playlistsProvider);

    final isDataTab = _tabController.index == 0;
    final isPlaylistTab = _tabController.index == 1;

    // 検索フィルター
    const untaggedId = '__untagged__';
    final hasUntaggedFilter = filterTagIds.contains(untaggedId);
    final tagOnlyFilter =
        filterTagIds.where((id) => id != untaggedId).toSet();
    var filtered = filterTagIds.isEmpty
        ? allItems
        : allItems.where((i) {
            if (hasUntaggedFilter && i.tagIds.isEmpty) return true;
            if (tagOnlyFilter.isNotEmpty) {
              return tagOnlyFilter.every((tid) => i.tagIds.contains(tid));
            }
            return false;
          }).toList();
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered
          .where((i) =>
              i.title.toLowerCase().contains(q) ||
              (i.memo ?? '').toLowerCase().contains(q))
          .toList();
    }

    // ソート
    final items = List<LoopItem>.from(filtered);
    switch (_sortMode) {
      case _SortMode.updatedDesc:
        items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case _SortMode.updatedAsc:
        items.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      case _SortMode.titleAsc:
        items.sort((a, b) => a.title.compareTo(b.title));
      case _SortMode.titleDesc:
        items.sort((a, b) => b.title.compareTo(a.title));
      case _SortMode.createdDesc:
        items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }

    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _clearSelection();
      },
      child: Scaffold(
        appBar: _buildNormalAppBar(isDataTab, items),
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: Column(
          children: [
            // 検索・ソートバー
            if (isDataTab)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          decoration: InputDecoration(
                            hintText: '検索...',
                            hintStyle: const TextStyle(fontSize: 13),
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? GestureDetector(
                                    onTap: () {
                                      _searchController.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                    child: const Icon(Icons.close, size: 18),
                                  )
                                : null,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 0),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide:
                                  BorderSide(color: Colors.grey.shade700),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide:
                                  BorderSide(color: Colors.grey.shade700),
                            ),
                          ),
                          style: const TextStyle(fontSize: 13),
                          onChanged: (v) => setState(() => _searchQuery = v),
                        ),
                      ),
                    ),
                    if (tags.isNotEmpty)
                      _buildTagFilterButton(tags, filterTagIds),
                    PopupMenuButton<_SortMode>(
                      icon: const Icon(Icons.sort, size: 22),
                      tooltip: '並び替え',
                      onSelected: (mode) =>
                          setState(() => _sortMode = mode),
                      itemBuilder: (_) => [
                        _sortMenuItem(_SortMode.updatedDesc, '更新日（新→古）'),
                        _sortMenuItem(_SortMode.updatedAsc, '更新日（古→新）'),
                        _sortMenuItem(_SortMode.createdDesc, '作成日（新→古）'),
                        _sortMenuItem(_SortMode.titleAsc, 'タイトル（A→Z）'),
                        _sortMenuItem(_SortMode.titleDesc, 'タイトル（Z→A）'),
                      ],
                    ),
                  ],
                ),
              ),
            // 選択中タグの表示
            if (isDataTab && filterTagIds.isNotEmpty)
              _buildSelectedTagBar(tags, filterTagIds),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics:
                    _isSelecting ? const NeverScrollableScrollPhysics() : null,
                children: [
                  items.isEmpty
                      ? _buildEmpty(
                          Icons.music_note_outlined,
                          filterTagIds.isNotEmpty
                              ? '該当するデータがありません'
                              : 'データがありません',
                          filterTagIds.isNotEmpty
                              ? 'フィルターを変更してください'
                              : '＋ ボタンで追加',
                        )
                      : _buildItemsView(items, tags),
                  playlists.isEmpty
                      ? _buildEmpty(
                          Icons.playlist_play, 'プレイリストがありません', '＋ ボタンで新規作成')
                      : _buildPlaylistList(playlists),
                  _buildTagManagerTab(tags, allItems),
                ],
              ),
            ),
          ],
        )),
        floatingActionButton: _isSelecting
            ? null
            : _tabController.index == 0
                ? FloatingActionButton(
                    onPressed: _showAddDialog,
                    child: const Icon(Icons.add),
                  )
                : _tabController.index == 1
                    ? FloatingActionButton.extended(
                        onPressed: _createPlaylist,
                        icon: const Icon(Icons.playlist_add),
                        label: const Text('作成'),
                      )
                    : null,
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar(bool isDataTab, List<LoopItem> items) {
    return AppBar(
      title: const Text(
        'U2B Loop',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
      ),
      centerTitle: false,
      actions: [
        if (isDataTab) ...[
          IconButton(
            icon: Icon(_viewModeIcon),
            onPressed: _cycleViewMode,
            tooltip: _viewModeTooltip,
          ),
        ],
        IconButton(
          icon: const Icon(Icons.settings, size: 22),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
          tooltip: '設定',
        ),
      ],
      bottom: _isSelecting
          ? PreferredSize(
              preferredSize: const Size.fromHeight(46),
              child: _buildSelectionBar(items),
            )
          : TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: '曲リスト'),
                Tab(text: 'プレイリスト'),
                Tab(text: 'タグ管理'),
              ],
            ),
    );
  }

  Widget _buildSelectionBar(List<LoopItem> items) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          GestureDetector(
            onTap: _clearSelection,
            child: const Icon(Icons.close, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Text('${_selectedIds.length} 件選択',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const Spacer(),
          _selectionAction(
              Icons.playlist_add, 'PL追加', _showAddToPlaylistSheet),
          _selectionAction(
              Icons.label_outline, 'タグ', _showBulkTagSheet),
          _selectionAction(
              Icons.select_all, '全選択', () => _selectAll(items)),
          _selectionAction(
              Icons.delete_outline, '削除', _deleteSelected,
              color: Colors.red),
        ],
      ),
    );
  }

  Widget _selectionAction(
      IconData icon, String label, VoidCallback onTap,
      {Color? color}) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            Text(label,
                style: TextStyle(fontSize: 9, color: color ?? Colors.grey)),
          ],
        ),
      ),
    );
  }

  PopupMenuEntry<_SortMode> _sortMenuItem(_SortMode mode, String label) {
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          if (_sortMode == mode)
            const Icon(Icons.check, size: 18)
          else
            const SizedBox(width: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  // === タグフィルターバー ===

  Widget _buildTagFilterButton(List<Tag> tags, Set<String> filterTagIds) {
    const untaggedId = '__untagged__';
    return Stack(
      children: [
        IconButton(
          icon: const Icon(Icons.label_outline, size: 22),
          tooltip: 'タグフィルター',
          onPressed: () {
            var selected = Set<String>.from(filterTagIds);
            showModalBottomSheet(
              context: context,
              builder: (ctx) => StatefulBuilder(
                builder: (ctx, setSheetState) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Row(
                          children: [
                            const Text('タグフィルター',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                            const Spacer(),
                            if (selected.isNotEmpty)
                              TextButton(
                                onPressed: () {
                                  ref.read(tagFilterProvider.notifier)
                                      .state = {};
                                  Navigator.pop(ctx);
                                },
                                child: const Text('クリア',
                                    style: TextStyle(fontSize: 13)),
                              ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      CheckboxListTile(
                        title: const Text('未分類',
                            style: TextStyle(fontSize: 14)),
                        secondary:
                            const Icon(Icons.label_off, size: 20),
                        value: selected.contains(untaggedId),
                        onChanged: (_) {
                          setSheetState(() {
                            if (selected.contains(untaggedId)) {
                              selected.remove(untaggedId);
                            } else {
                              selected.add(untaggedId);
                            }
                          });
                          ref.read(tagFilterProvider.notifier).state =
                              Set.from(selected);
                        },
                      ),
                      for (final tag in tags)
                        CheckboxListTile(
                          title: Text(tag.name,
                              style: const TextStyle(fontSize: 14)),
                          value: selected.contains(tag.id),
                          onChanged: (_) {
                            setSheetState(() {
                              if (selected.contains(tag.id)) {
                                selected.remove(tag.id);
                              } else {
                                selected.add(tag.id);
                              }
                            });
                            ref.read(tagFilterProvider.notifier).state =
                                Set.from(selected);
                          },
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        if (filterTagIds.isNotEmpty)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: AppTheme.accentGreen,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${filterTagIds.length}',
                style: const TextStyle(fontSize: 9, color: Colors.black),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSelectedTagBar(List<Tag> tags, Set<String> filterTagIds) {
    const untaggedId = '__untagged__';
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        children: [
          if (filterTagIds.contains(untaggedId))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Chip(
                avatar: const Icon(Icons.label_off, size: 14),
                label:
                    const Text('未分類', style: TextStyle(fontSize: 11)),
                onDeleted: () {
                  ref.read(tagFilterProvider.notifier).update((s) {
                    final next = Set<String>.from(s);
                    next.remove(untaggedId);
                    return next;
                  });
                },
                deleteIconColor: Colors.grey,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          for (final tag in tags)
            if (filterTagIds.contains(tag.id))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Chip(
                  label:
                      Text(tag.name, style: const TextStyle(fontSize: 11)),
                  onDeleted: () {
                    ref.read(tagFilterProvider.notifier).update((s) {
                      final next = Set<String>.from(s);
                      next.remove(tag.id);
                      return next;
                    });
                  },
                  deleteIconColor: Colors.grey,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ActionChip(
              label: const Text('クリア', style: TextStyle(fontSize: 11)),
              onPressed: () {
                ref.read(tagFilterProvider.notifier).state = {};
              },
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  // === Items view ===

  Widget _buildItemsView(List<LoopItem> items, List<Tag> tags) {
    return switch (_viewMode) {
      _ViewMode.list => _buildListView(items, tags),
      _ViewMode.grid2 => _buildGridView(items, tags, 2, 16 / 12),
      _ViewMode.grid4 => _buildGridView(items, tags, 4, 16 / 11),
    };
  }

  // === Grid view ===

  Widget _buildGridView(
      List<LoopItem> items, List<Tag> tags, int cols, double ratio) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(6, 6, 6, 6 + bottomPad),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: ratio,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) =>
          _buildCard(items[i], tags, compact: cols >= 4),
    );
  }

  Widget _buildCard(LoopItem item, List<Tag> tags, {bool compact = false}) {
    final selected = _selectedIds.contains(item.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: Theme.of(context).colorScheme.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: () => _openDetail(item),
        onLongPress: () => _startSelect(item),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _buildThumbnail(item),
                ),
                if (!compact)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                          if (item.isReady) ...[
                            if (_buildRegionInfoText(item) != null)
                              Text(
                                _buildRegionInfoText(item)!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 9, color: Colors.grey),
                              ),
                            if (item.memo != null && item.memo!.isNotEmpty)
                              Text(
                                item.memo!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.grey.shade600),
                              ),
                          ],
                          if (item.tagIds.isNotEmpty)
                            _buildTagChips(item, tags, tiny: true),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (item.isFetching || item.hasError)
              Positioned.fill(child: _buildStatusOverlay(item)),
            if (selected)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child:
                      const Icon(Icons.check, size: 14, color: Colors.white),
                ),
              ),
            if (_isSelecting && !selected)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white54, width: 2),
                  ),
                  width: 20,
                  height: 20,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagChips(LoopItem item, List<Tag> tags, {bool tiny = false}) {
    final itemTags = tags.where((t) => item.tagIds.contains(t.id)).toList();
    if (itemTags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 3,
      runSpacing: 0,
      children: itemTags
          .map((t) => Container(
                padding: EdgeInsets.symmetric(
                    horizontal: tiny ? 4 : 6, vertical: tiny ? 0 : 1),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(t.name,
                    style: TextStyle(fontSize: tiny ? 8 : 10)),
              ))
          .toList(),
    );
  }

  // === List view ===

  Widget _buildListView(List<LoopItem> items, List<Tag> tags) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return ListView.builder(
      padding: EdgeInsets.only(top: 4, bottom: 4 + bottomPad),
      itemCount: items.length,
      itemBuilder: (context, i) => _buildListTile(items[i], tags),
    );
  }

  Widget _buildListTile(LoopItem item, List<Tag> tags) {
    final selected = _selectedIds.contains(item.id);
    return ListTile(
      selected: selected,
      leading: _isSelecting
          ? Checkbox(
              value: selected,
              onChanged: (_) => _toggleSelect(item),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 64,
                height: 36,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildThumbnail(item),
                    if (item.isFetching)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          ),
                        ),
                      ),
                    if (item.hasError)
                      Container(
                        color: Colors.black54,
                        child: const Icon(Icons.error_outline,
                            size: 18, color: Colors.orange),
                      ),
                  ],
                ),
              ),
            ),
      title: Text(
        item.isFetching ? 'データ取得中...' : item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          color: item.isFetching ? Colors.grey : null,
        ),
      ),
      subtitle: _buildSubtitle(item, tags),
      trailing: _isSelecting
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'delete') _deleteItem(item);
                if (v == 'retry') {
                  ref.read(loopItemsProvider.notifier).retryFetch(item);
                }
              },
              itemBuilder: (_) => [
                if (item.hasError)
                  const PopupMenuItem(value: 'retry', child: Text('再試行')),
                const PopupMenuItem(value: 'delete', child: Text('削除')),
              ],
            ),
      onTap: () => _openDetail(item),
      onLongPress: () => _startSelect(item),
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

  String? _buildRegionInfoText(LoopItem item) {
    final regions = item.effectiveRegions;
    final first = regions.firstOrNull;
    if (first == null || !first.hasPoints) return null;

    final parts = <String>[];

    // Show custom region name if not default
    if (first.name != '区間 1' && regions.length > 1) {
      parts.add(first.name);
    }

    // A-B times
    final aStr = first.hasA
        ? TimeUtils.formatShort(Duration(milliseconds: first.pointAMs!))
        : '--:--';
    final bStr = first.hasB
        ? TimeUtils.formatShort(Duration(milliseconds: first.pointBMs!))
        : '--:--';
    parts.add('A $aStr - B $bStr');

    // Additional regions count
    if (regions.length > 1) {
      final others = regions.length - 1;
      parts.add('他$others件');
    }

    return parts.join('  ');
  }

  Widget? _buildSubtitle(LoopItem item, List<Tag> tags) {
    if (item.isFetching) {
      return const Text('情報を取得中...',
          style: TextStyle(fontSize: 11, color: Colors.grey));
    }
    if (item.hasError) {
      return Text('取得失敗（タップで操作）',
          style: TextStyle(fontSize: 11, color: Colors.orange.shade300));
    }

    final parts = <Widget>[];
    final info = <String>[];
    final regionInfo = _buildRegionInfoText(item);
    if (regionInfo != null) info.add(regionInfo);
    if (item.speed != 1.0) info.add('${item.speed}x');
    if (item.memo != null && item.memo!.isNotEmpty) info.add(item.memo!);
    if (info.isNotEmpty) {
      parts.add(Text(info.join('  |  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.grey)));
    }
    if (item.tagIds.isNotEmpty) {
      parts.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: _buildTagChips(item, tags),
      ));
    }
    if (parts.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: parts,
    );
  }

  // === ステータスオーバーレイ ===

  Widget _buildStatusOverlay(LoopItem item) {
    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: item.isFetching
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                  SizedBox(height: 6),
                  Text('取得中...',
                      style: TextStyle(color: Colors.white, fontSize: 11)),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.orange, size: 28),
                  const SizedBox(height: 4),
                  Text('取得失敗',
                      style: TextStyle(
                          color: Colors.orange.shade300, fontSize: 11)),
                ],
              ),
      ),
    );
  }

  // === Tag Manager Tab ===

  Widget _buildTagManagerTab(List<Tag> tags, List<LoopItem> allItems) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    if (tags.isEmpty) {
      return _buildEmpty(Icons.label_outline, 'タグがありません', '曲の詳細画面からタグを作成');
    }

    return ListView.builder(
      padding: EdgeInsets.only(top: 4, bottom: 4 + bottomPad),
      itemCount: tags.length + 1, // +1 for add button
      itemBuilder: (context, i) {
        if (i == tags.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: () => _createTagFromTab(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('タグを作成'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.grey.shade700),
              ),
            ),
          );
        }

        final tag = tags[i];
        final count =
            allItems.where((item) => item.tagIds.contains(tag.id)).length;

        return ListTile(
          leading: const Icon(Icons.label_outline, size: 20),
          title: Text(tag.name, style: const TextStyle(fontSize: 14)),
          trailing: Text('$count 曲',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          onTap: () {
            // 曲リストタブに移動してこのタグでフィルター
            ref.read(tagFilterProvider.notifier).state = {tag.id};
            _tabController.animateTo(0);
          },
          onLongPress: () => _showTagMenu(tag),
        );
      },
    );
  }

  void _createTagFromTab() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('タグを作成'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.tagNameMaxLength,
          decoration: const InputDecoration(
            hintText: 'タグ名',
            hintStyle: kHintStyle,
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
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('作成'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    ref.read(tagsProvider.notifier).create(name);
  }

  void _showTagMenu(Tag tag) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('リネーム'),
              onTap: () {
                Navigator.pop(ctx);
                _renameTagFromTab(tag);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('削除',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(tagFilterProvider.notifier).update(
                    (s) => s..remove(tag.id));
                ref.read(tagsProvider.notifier).delete(tag.id);
                ref.read(loopItemsProvider.notifier).removeTagFromAll(tag.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _renameTagFromTab(Tag tag) async {
    final controller = TextEditingController(text: tag.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('タグ名変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.tagNameMaxLength,
          decoration: const InputDecoration(
            hintText: 'タグ名',
            hintStyle: kHintStyle,
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
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    ref.read(tagsProvider.notifier).rename(tag.id, name);
  }

  // === Playlist ===

  Widget _buildPlaylistList(List<Playlist> playlists) {
    final items = ref.watch(loopItemsProvider);
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return ListView.builder(
      padding: EdgeInsets.only(top: 4, bottom: 4 + bottomPad),
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
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) =>
                      PlaylistDetailScreen(playlistId: pl.id)),
            );
          },
        );
      },
    );
  }

  // === Empty / Thumbnail ===

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
          size: _viewMode == _ViewMode.grid4 ? 16 : null,
        ),
      ),
    );
  }
}

// ============================================================
// 複数選択タグ操作シート
// ============================================================

class _BulkTagSheet extends StatefulWidget {
  final List<Tag> tags;
  final List<LoopItem> selectedItems;
  final void Function(String tagId) onAddTag;
  final void Function(String tagId) onRemoveTag;
  final VoidCallback onClearTags;
  final Future<Tag> Function(String name) onCreateTag;

  const _BulkTagSheet({
    required this.tags,
    required this.selectedItems,
    required this.onAddTag,
    required this.onRemoveTag,
    required this.onClearTags,
    required this.onCreateTag,
  });

  @override
  State<_BulkTagSheet> createState() => _BulkTagSheetState();
}

class _BulkTagSheetState extends State<_BulkTagSheet> {
  late List<Tag> _tags;

  @override
  void initState() {
    super.initState();
    _tags = List.from(widget.tags);
  }

  // タグが全選択アイテムについているか
  bool _allHaveTag(String tagId) =>
      widget.selectedItems.every((i) => i.tagIds.contains(tagId));

  // タグが一部のアイテムについているか
  bool _someHaveTag(String tagId) =>
      widget.selectedItems.any((i) => i.tagIds.contains(tagId));

  void _showNewTagInput() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新しいタグ'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.tagNameMaxLength,
          decoration: const InputDecoration(
            hintText: 'タグ名',
            hintStyle: kHintStyle,
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
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('作成'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      final tag = await widget.onCreateTag(name);
      widget.onAddTag(tag.id);
      setState(() => _tags.add(tag));
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text(
                    'タグ（${widget.selectedItems.length}件に適用）',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      widget.onClearTags();
                      Navigator.pop(context);
                    },
                    child: const Text('すべて解除',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
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
                value: _allHaveTag(tag.id)
                    ? true
                    : _someHaveTag(tag.id)
                        ? null
                        : false,
                tristate: true,
                onChanged: (val) {
                  if (val == true || val == null) {
                    widget.onAddTag(tag.id);
                  } else {
                    widget.onRemoveTag(tag.id);
                  }
                  setState(() {});
                },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: OutlinedButton.icon(
                onPressed: _showNewTagInput,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新しいタグを作成'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// タグ管理シート（名前変更・削除・新規作成）
// ============================================================

class _TagManagerSheet extends StatefulWidget {
  final List<Tag> tags;
  final void Function(String id, String name) onRename;
  final void Function(String id) onDelete;
  final void Function(String name) onCreate;

  const _TagManagerSheet({
    required this.tags,
    required this.onRename,
    required this.onDelete,
    required this.onCreate,
  });

  @override
  State<_TagManagerSheet> createState() => _TagManagerSheetState();
}

class _TagManagerSheetState extends State<_TagManagerSheet> {
  late List<Tag> _tags;

  @override
  void initState() {
    super.initState();
    _tags = List.from(widget.tags);
  }

  void _rename(Tag tag) async {
    final controller = TextEditingController(text: tag.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('タグ名変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.tagNameMaxLength,
          decoration: const InputDecoration(
            hintText: 'タグ名',
            hintStyle: kHintStyle,
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
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('変更'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName != null && newName.isNotEmpty && newName != tag.name) {
      widget.onRename(tag.id, newName);
      setState(() => tag.name = newName);
    }
  }

  void _delete(Tag tag) {
    widget.onDelete(tag.id);
    setState(() => _tags.remove(tag));
  }

  void _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新しいタグ'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.tagNameMaxLength,
          decoration: const InputDecoration(
            hintText: 'タグ名',
            hintStyle: kHintStyle,
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
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('作成'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      widget.onCreate(name);
      // シートを閉じて再表示で反映（簡易対応）
      if (mounted) Navigator.pop(context);
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
              child: Text('タグ管理',
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
              ListTile(
                title: Text(tag.name, style: const TextStyle(fontSize: 14)),
                leading: const Icon(Icons.label_outline, size: 20),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () => _rename(tag),
                      tooltip: '名前変更',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: Colors.red),
                      onPressed: () => _delete(tag),
                      tooltip: '削除',
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: OutlinedButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新しいタグを作成'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// YouTubeプレイリスト動画選択ページ
// ============================================================

class _PlaylistVideoSelectPage extends StatefulWidget {
  final List<yte.Video> videos;
  final Set<String> duplicateIds;
  final String playlistTitle;
  final void Function(List<yte.Video> selected) onConfirm;

  const _PlaylistVideoSelectPage({
    required this.videos,
    required this.duplicateIds,
    required this.playlistTitle,
    required this.onConfirm,
  });

  @override
  State<_PlaylistVideoSelectPage> createState() =>
      _PlaylistVideoSelectPageState();
}

class _PlaylistVideoSelectPageState extends State<_PlaylistVideoSelectPage> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    // デフォルトで新規のものを全選択
    _selected = widget.videos
        .where((v) => !widget.duplicateIds.contains(v.id.value))
        .map((v) => v.id.value)
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selected.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlistTitle,
            style: const TextStyle(fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          FilledButton(
            onPressed: selectedCount == 0
                ? null
                : () {
                    final selected = widget.videos
                        .where((v) => _selected.contains(v.id.value))
                        .toList();
                    widget.onConfirm(selected);
                    Navigator.pop(context);
                  },
            child: Text('追加 ($selectedCount)'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 一括選択バー
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Text('${widget.videos.length}件中 $selectedCount件選択',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _selected =
                        widget.videos.map((v) => v.id.value).toSet();
                  }),
                  child: const Text('すべて選択', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: const Text('すべて解除', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.videos.length,
              itemBuilder: (context, i) {
                final video = widget.videos[i];
                final id = video.id.value;
                final isDuplicate = widget.duplicateIds.contains(id);
                final isSelected = _selected.contains(id);

                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 64,
                      height: 36,
                      child: Image.network(
                        video.thumbnails.lowResUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: const Icon(Icons.play_circle_outline,
                              color: Colors.grey, size: 18),
                        ),
                      ),
                    ),
                  ),
                  title: Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: isDuplicate
                      ? const Text('登録済み',
                          style: TextStyle(
                              fontSize: 11, color: Colors.orange))
                      : null,
                  trailing: Checkbox(
                    value: isSelected,
                    onChanged: (_) => setState(() {
                      if (isSelected) {
                        _selected.remove(id);
                      } else {
                        _selected.add(id);
                      }
                    }),
                  ),
                  onTap: () => setState(() {
                    if (isSelected) {
                      _selected.remove(id);
                    } else {
                      _selected.add(id);
                    }
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
