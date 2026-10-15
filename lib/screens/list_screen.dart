
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../core/utils/url_utils.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import '../providers/easter_egg_provider.dart';
import '../services/playlist_service.dart';
import '../services/share_service.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/glass_surface.dart';
import '../widgets/item_thumbnail.dart';
import '../widgets/tag_chip.dart';
import '../widgets/loading_animations/loading_animation_widget.dart';
import '../widgets/loading_animations/loading_animation.dart';
import '../widgets/share_import_dialog.dart';

import 'detail_screen.dart';
import 'player_screen.dart';
import 'playlist_detail_screen.dart';
import 'settings_screen.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/app_errors.dart';
import '../core/utils/id_generator.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';

/// 表示モード: リスト / 2列 / 4列
enum _ViewMode { list, grid2, grid4 }

enum _SortMode { updatedDesc, updatedAsc, titleAsc, titleDesc, createdDesc, playCountDesc }

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

  /// AppBar の「選択」で入ったとき（まだ何も選んでいなくても選択中として扱う）
  bool _selectMode = false;
  bool get _isSelecting => _selectMode || _selectedIds.isNotEmpty;

  String _searchQuery = '';
  _SortMode _sortMode = _SortMode.updatedDesc;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(skipTraversal: true);
  bool _matrixActive = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 1);
    _tabController.addListener(() => setState(() {}));
    // スワイプ中にタブ0の閾値を超えたら即座にUI切り替え
  }

  /// showModalBottomSheet のラッパー。閉じた後にフォーカスを解除する。
  Future<T?> _showSheet<T>({required WidgetBuilder builder, bool isScrollControlled = false}) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      builder: builder,
    ).then((result) {
      _searchFocusNode.unfocus();
      return result;
    });
  }

  void _triggerMatrixEasterEgg() {
    if (_matrixActive) return;
    final unlocked = ref.read(easterEggProvider.notifier).unlockMatrix();
    setState(() => _matrixActive = true);
    if (unlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success('💊 マトリックスモードがアンロックされました！'),
      );
    }
    Future.delayed(const Duration(seconds: 10), () {
      if (mounted) setState(() => _matrixActive = false);
    });
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

      // 共有URL
      if (url.startsWith('u2bloop://')) {
        Navigator.pop(dialogCtx);
        final data = ShareService.decode(url);
        if (data != null && mounted) {
          showShareImportDialog(context, ref, data);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            AppSnackBar.info('無効な共有URLです'),
          );
        }
        return;
      }

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
            title: Text('どちらを追加しますか？',
                style: Theme.of(context).textTheme.titleMedium),
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
            AppSnackBar.success('追加しました（情報を取得中...）'),
          );
        }
        return;
      }

      if (videoId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar.info('無効なYouTube URLです'),
        );
        return;
      }
      ref.read(loopItemsProvider.notifier).addYouTubeAndFetch(videoId, url);
      Navigator.pop(dialogCtx);
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success('追加しました（情報を取得中...）'),
      );
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('追加', style: Theme.of(context).textTheme.displaySmall),
        // 横画面でキーボードが出ても溢れないように
        scrollable: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
        ],
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              autofocus: true,
              maxLength: AppLimits.urlMaxLength,
              decoration: const InputDecoration(
                hintText: 'YouTube URL / 共有URL',
                prefixIcon: Icon(Icons.link, size: AppIconSizes.sm),
                isDense: true,
                border: OutlineInputBorder(),
                counterText: '',
              ),
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 3,
              minLines: 3,
              onSubmitted: (_) => doAdd(ctx),
            ),
            const SizedBox(height: AppSpacing.md),
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
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Text('または',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.4))),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _addLocalFile();
                },
                icon: const Icon(Icons.folder_open, size: AppIconSizes.sm),
                label: const Text('ローカルファイルを選択'),
              ),
            ),
          ],
        ),
      ),
    ).then((_) {
      // ダイアログのアニメーション完了後にdispose
      Future.delayed(const Duration(milliseconds: 300), () {
        urlController.dispose();
      });
    });
  }

  Future<void> _addLocalFile() async {
    // file_picker はAndroidで選択ファイルをキャッシュへコピーしてから返すため、
    // 大きい動画だとコピー完了まで待たされる。その間ローディングを表示する。
    var loadingShown = false;
    void showCopyLoading() {
      if (loadingShown || !mounted) return;
      loadingShown = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: AppIconSizes.md,
                      height: AppIconSizes.md,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: AppSpacing.xl),
                    Text('ファイルを読み込み中...'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    void hideCopyLoading() {
      if (loadingShown && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      loadingShown = false;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
        onFileLoading: (status) {
          if (status == FilePickerStatus.picking) {
            showCopyLoading();
          } else {
            hideCopyLoading();
          }
        },
      );
    } finally {
      hideCopyLoading();
    }
    if (result == null || result.files.isEmpty) return;

    // path（ファイルパス）またはidentifier（content:// URI）を使用
    final files = <({String path, String name})>[];
    for (final f in result.files) {
      final uri = f.path ?? f.identifier;
      if (uri == null || uri.isEmpty) continue;
      files.add((path: uri, name: f.name));
    }
    if (files.isEmpty) return;

    final count = ref.read(loopItemsProvider.notifier).addLocalFilesSync(files);
    if (mounted && count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success('$count件追加しました（サムネイル取得中...）'),
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
    // 進捗ダイアログを閉じたあとに例外が起きると、catch節のpopが
    // 一覧画面自体をpopしてしまうため、閉じたかどうかを覚えておく
    var progressDialogOpen = true;
    void closeProgressDialog() {
      if (!progressDialogOpen) return;
      progressDialogOpen = false;
      if (mounted) Navigator.pop(context);
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<String>(
          valueListenable: statusNotifier,
          builder: (_, status, _) => ValueListenableBuilder<int>(
            valueListenable: countNotifier,
            builder: (_, count, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: AppIconSizes.lg,
                      height: AppIconSizes.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: AppSpacing.xl),
                    Expanded(child: Text(status, style: Theme.of(context).textTheme.bodyLarge)),
                  ],
                ),
                if (count > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: Text('$count 件取得済み',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _importCancelled = true;
              closeProgressDialog();
            },
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );

    try {
      try {
        statusNotifier.value = 'プレイリスト情報を取得中...';
        final data = await PlaylistService().fetch(
          playlistId,
          isCancelled: () => _importCancelled,
          onProgress: (count) {
            countNotifier.value = count;
            if (count > 0) statusNotifier.value = '動画を取得中...';
          },
        );
        if (_importCancelled || !mounted) return;
        closeProgressDialog();

        final videos = data.videos;
        if (videos.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            AppSnackBar.info(playlistId.startsWith('RD')
                ? 'ミックスリストの取得に失敗しました（YouTube側の制限の可能性）'
                : 'プレイリストに動画がありません'),
          );
          return;
        }

        final playlistTitle = data.title.isNotEmpty ? data.title : 'プレイリスト';

        // 既存アイテムとの重複チェック
        final existingItems = ref.read(loopItemsProvider);
        final existingVideoIds =
            existingItems.map((i) => i.videoId).whereType<String>().toSet();
        final duplicates =
            videos.where((v) => existingVideoIds.contains(v.id)).toList();
        final newVideos =
            videos.where((v) => !existingVideoIds.contains(v.id)).toList();

        if (duplicates.isEmpty) {
          _addVideos(videos, playlistTitle);
        } else {
          await _showDuplicateDialog(
            playlistTitle: playlistTitle,
            allVideos: videos,
            newVideos: newVideos,
            duplicates: duplicates,
          );
        }
      } finally {
        countNotifier.dispose();
        statusNotifier.dispose();
      }
    } catch (e) {
      if (_importCancelled) return;
      closeProgressDialog();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar.error('取得に失敗しました: ${AppErrors.describe(e)}'),
        );
      }
    }
  }

  Future<void> _addVideos(
      List<PlaylistVideoInfo> videos, String playlistTitle) async {
    // タグを選択/作成するダイアログ
    final tagId = await _showImportTagDialog(playlistTitle);
    if (!mounted) return;

    // 即座にHive保存（サムネイルDLなし）→ UIに即反映
    final notifier = ref.read(loopItemsProvider.notifier);
    final addedIds = await notifier.addYouTubeBatch(
      videos: videos
          .map((v) => (
                videoId: v.id,
                title: v.title,
                url: 'https://youtu.be/${v.id}',
                thumbnailUrl: v.thumbnailHighUrl,
              ))
          .toList(),
      tagId: tagId,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success(
            '「$playlistTitle」から${addedIds.length}曲を追加しました'),
      );
    }

    // サムネイルをバックグラウンドでダウンロード
    if (addedIds.isNotEmpty) {
      notifier.downloadThumbnailsInBackground(addedIds);
    }
  }

  /// インポート時にタグを付与するか選択するダイアログ
  Future<String?> _showImportTagDialog(String playlistTitle) async {
    final tags = ref.read(tagsProvider);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('タグを付与', style: Theme.of(context).textTheme.titleMedium),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('追加する曲に共通のタグを付けますか？',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.muted(context))),
            const SizedBox(height: AppSpacing.lg),
            // 既存タグ
            if (tags.isNotEmpty)
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final tag in tags)
                    ActionChip(
                      label: Text(tag.name,
                          style: Theme.of(context).textTheme.labelMedium),
                      onPressed: () => Navigator.pop(ctx, tag.id),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            const SizedBox(height: AppSpacing.md),
            // プレイリスト名で新規作成
            OutlinedButton.icon(
              onPressed: () async {
                final tag = await ref
                    .read(tagsProvider.notifier)
                    .create(playlistTitle);
                if (ctx.mounted) Navigator.pop(ctx, tag.id);
              },
              icon: const Icon(Icons.add, size: AppIconSizes.s),
              label: Text('「$playlistTitle」タグを作成',
                  style: Theme.of(context).textTheme.labelMedium),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Theme.of(context).dividerColor),
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
    required List<PlaylistVideoInfo> allVideos,
    required List<PlaylistVideoInfo> newVideos,
    required List<PlaylistVideoInfo> duplicates,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$playlistTitle (${allVideos.length}件)',
            style: Theme.of(context).textTheme.titleMedium),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${duplicates.length}件が既に登録されています。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (newVideos.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  '新規: ${newVideos.length}件',
                  style: Theme.of(context).textTheme.bodySmall,
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
    List<PlaylistVideoInfo> allVideos,
    List<PlaylistVideoInfo> duplicates,
    String playlistTitle,
  ) {
    final duplicateIds = duplicates.map((v) => v.id).toSet();
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
        AppSnackBar.info('データ取得中です...'),
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
    AppSheets.actions(
      context,
      title: item.title,
      subtitle: '情報を取得できませんでした',
      actions: [
        SheetAction(
          icon: Icons.refresh,
          label: '再試行',
          onTap: () => ref.read(loopItemsProvider.notifier).retryFetch(item),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => _deleteItem(item),
        ),
      ],
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
    setState(() {
      _selectMode = true;
      _selectedIds.add(item.id);
    });
  }

  /// AppBar の「選択」から。長押しを知らなくても入れるように
  void _enterSelectMode() {
    setState(() => _selectMode = true);
  }

  void _selectAll(List<LoopItem> items) {
    setState(() {
      for (final item in items) {
        _selectedIds.add(item.id);
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIds.length;
    final confirmed = await AppDialogs.confirmDelete(context,
        message: '選択した $count 件を削除しますか？');
    if (confirmed) {
      final ids = Set<String>.from(_selectedIds);
      _clearSelection();
      for (final id in ids) {
        await ref.read(loopItemsProvider.notifier).delete(id);
      }
    }
  }

  // --- 複数選択タグ操作 ---

  void _showBulkTagSheet() {
    _searchFocusNode.unfocus();
    final tags = ref.read(tagsProvider);
    final items = ref.read(loopItemsProvider);
    final selectedItems =
        items.where((i) => _selectedIds.contains(i.id)).toList();

    _showSheet(
      builder: (ctx) => _BulkTagSheet(
        tags: tags,
        selectedItems: selectedItems,
        allItems: items,
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
    _searchFocusNode.unfocus();
    final playlists = ref.read(playlistsProvider);
    final allItems = ref.read(loopItemsProvider);
    _showSheet(builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
              child: Text(
                'プレイリストに追加（${_selectedIds.length}件）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('プレイリストがありません',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.muted(context))),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (_, i) {
                  final pl = playlists[i];
                  final count = pl.itemIds
                      .where((id) =>
                          allItems.any((item) => item.id == id))
                      .length;
                  final thumbItemId = pl.effectiveThumbnailItemId;
                  final thumbItem = thumbItemId != null
                      ? allItems
                          .where((item) => item.id == thumbItemId)
                          .firstOrNull
                      : null;
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: AppRadius.borderXs,
                      child: SizedBox(
                        width: 48,
                        height: 36,
                        child: thumbItem != null
                            ? ItemThumbnail(item: thumbItem)
                            : Container(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: Icon(Icons.playlist_play,
                                    color: AppTheme.muted(context),
                                    size: AppIconSizes.md),
                              ),
                      ),
                    ),
                    title: Text(pl.name,
                        style: Theme.of(context).textTheme.bodyLarge),
                    subtitle: Text('$count 曲',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppTheme.muted(context))),
                    onTap: () {
                      Navigator.pop(ctx);
                      final ids = _selectedIds.toList();
                      ref
                          .read(playlistsProvider.notifier)
                          .addItems(pl.id, ids);
                      _clearSelection();
                      ScaffoldMessenger.of(context).showSnackBar(
                        AppSnackBar.success(
                            '${ids.length}件を「${pl.name}」に追加しました'),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text('新規作成して追加',
                  style: Theme.of(context).textTheme.bodyLarge),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await AppDialogs.prompt(context,
                    title: 'プレイリスト作成',
                    hintText: 'プレイリスト名',
                    confirmLabel: '作成',
                    maxLength: AppLimits.playlistNameMaxLength);
                if (name != null) {
                  final pl = Playlist(
                    id: IdGenerator.next(),
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
                      AppSnackBar.success(
                          '${ids.length}件を「${pl.name}」に追加しました'),
                    );
                  }
                }
              },
            ),
            const SizedBox(height: AppSpacing.md),
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

  // --- プレイリスト ---

  Future<void> _createPlaylist() async {
    final name = await AppDialogs.prompt(context,
        title: 'プレイリスト作成',
        hintText: 'プレイリスト名',
        confirmLabel: '作成',
        maxLength: AppLimits.playlistNameMaxLength);
    if (name != null) {
      ref.read(playlistsProvider.notifier).add(Playlist(
            id: IdGenerator.next(),
            name: name,
          ));
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirmed = await AppDialogs.confirmDelete(context,
        message: '「${playlist.name}」を削除しますか？');
    if (confirmed) {
      ref.read(playlistsProvider.notifier).delete(playlist.id);
    }
  }

  void _playPlaylist(Playlist pl, List<LoopItem> allItems) {
    final plItems = pl.itemIds
        .map((id) => allItems.where((item) => item.id == id).firstOrNull)
        .whereType<LoopItem>()
        .toList();
    if (plItems.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: plItems.first,
          playlistItems: plItems,
          regionSelections:
              pl.regionSelections.isNotEmpty ? pl.regionSelections : null,
          disabledItemIds:
              pl.disabledItemIds.isNotEmpty ? pl.disabledItemIds : null,
          playlistName: pl.name,
          playlistId: pl.id,
        ),
      ),
    );
  }

  void _duplicatePlaylist(Playlist playlist) {
    ref.read(playlistsProvider.notifier).duplicate(playlist.id);
  }

  // === Build ===

  @override
  Widget build(BuildContext context) {
    final allItems = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);
    final filterTagIds = ref.watch(tagFilterProvider);
    final playlists = ref.watch(playlistsProvider);

    final isDataTab = _tabController.index == 1;

    // 検索フィルター
    const untaggedId = '__untagged__';
    final includeTags = filterTagIds.entries
        .where((e) => e.value && e.key != untaggedId)
        .map((e) => e.key)
        .toSet();
    final excludeTags = filterTagIds.entries
        .where((e) => !e.value && e.key != untaggedId)
        .map((e) => e.key)
        .toSet();
    final includeUntagged = filterTagIds[untaggedId] == true;
    final excludeUntagged = filterTagIds[untaggedId] == false;
    var filtered = filterTagIds.isEmpty
        ? allItems
        : allItems.where((i) {
            // 除外判定（1つでも該当すれば除外）
            if (excludeUntagged && i.tagIds.isEmpty) return false;
            if (excludeTags.any((tid) => i.tagIds.contains(tid))) return false;
            // 包含判定
            if (includeTags.isEmpty && !includeUntagged) return true;
            if (includeUntagged && i.tagIds.isEmpty) return true;
            if (includeTags.isNotEmpty) {
              return includeTags.every((tid) => i.tagIds.contains(tid));
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
      case _SortMode.playCountDesc:
        items.sort((a, b) => b.playCount.compareTo(a.playCount));
    }

    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _clearSelection();
      },
      child: Scaffold(
        // ガラス風: 背景を AppBar の裏まで通す。本文の上端は Builder の context から取る
        // （State の context は Scaffold の外なので AppBar の高さが入らない）
        extendBodyBehindAppBar: true,
        appBar: _buildNormalAppBar(isDataTab, items),
        body: Stack(
          children: [
            const Positioned.fill(child: AppBackdrop()),
            SafeArea(
          top: false,
          bottom: false,
          child: Stack(
          children: [
            GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: Builder(builder: (bodyContext) => Column(
          children: [
            SizedBox(height: MediaQuery.paddingOf(bodyContext).top + AppSpacing.xs),
            // タブ（選択中は操作バー）: ガラスのセグメント
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: _isSelecting
                  ? _buildSelectionBar(items)
                  : GlassSegmentedTabs(
                      controller: _tabController,
                      labels: const ['タグ', '曲', 'プレイリスト'],
                    ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics:
                    _isSelecting ? const NeverScrollableScrollPhysics() : null,
                children: [
                  // タグ管理タブ
                  _buildTagManagerTab(tags, allItems),
                  // 曲リストタブ（検索バー含む）
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: GlassSearchField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                onChanged: (v) {
                                  setState(() => _searchQuery = v);
                                  if (v.toLowerCase() == 'matrix') {
                                    _triggerMatrixEasterEgg();
                                  }
                                },
                                onClear: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              ),
                            ),
                            if (tags.isNotEmpty) ...[
                              const SizedBox(width: AppSpacing.md),
                              _buildTagFilterButton(tags, filterTagIds),
                            ],
                            const SizedBox(width: AppSpacing.md),
                            PopupMenuButton<_SortMode>(
                              tooltip: '並び替え',
                              onSelected: (mode) =>
                                  setState(() => _sortMode = mode),
                              itemBuilder: (_) => [
                                _sortMenuItem(
                                    _SortMode.updatedDesc, '更新日（新→古）'),
                                _sortMenuItem(
                                    _SortMode.updatedAsc, '更新日（古→新）'),
                                _sortMenuItem(
                                    _SortMode.createdDesc, '作成日（新→古）'),
                                _sortMenuItem(
                                    _SortMode.titleAsc, 'タイトル（A→Z）'),
                                _sortMenuItem(
                                    _SortMode.titleDesc, 'タイトル（Z→A）'),
                                _sortMenuItem(
                                    _SortMode.playCountDesc, '再生回数（多→少）'),
                              ],
                              child: const GlassPill(
                                onTap: null,
                                padding: EdgeInsets.all(10),
                                child: Icon(Icons.sort, size: AppIconSizes.md),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (filterTagIds.isNotEmpty)
                        _buildSelectedTagBar(tags, filterTagIds),
                      Expanded(
                        child: items.isEmpty
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
                      ),
                    ],
                  ),
                  playlists.isEmpty
                      ? _buildEmpty(
                          Icons.playlist_play, 'プレイリストがありません', '＋ ボタンで新規作成')
                      : _buildPlaylistList(playlists),
                ],
              ),
            ),
          ],
        ))),
            if (_matrixActive)
              Positioned.fill(
                child: IgnorePointer(
                  child: LoadingAnimationView(
                    type: LoadingAnimationType.matrix,
                  ),
                ),
              ),
          ],
        ),
        ),
          ],
        ),
        // キーボードが出ている間は FAB を出さない。出したままだとキーボードの上に
        // 逃げ、閉じるときは先に定位置へ飛んでキーボードの裏に隠れ、キーボードが
        // 下がりきってから下から現れる、という動きに見える
        floatingActionButton: _isSelecting || keyboardOpen
            ? null
            : _tabController.index == 0
                ? GreenButton(
                    icon: Icons.new_label,
                    size: 56,
                    tooltip: 'タグを作成',
                    onPressed: _createTagFromTab,
                  )
                : _tabController.index == 1
                    ? GreenButton(
                        icon: Icons.add,
                        size: 56,
                        tooltip: '追加',
                        onPressed: _showAddDialog,
                      )
                    : GreenButton(
                        icon: Icons.playlist_add,
                        size: 56,
                        tooltip: 'プレイリストを作成',
                        onPressed: _createPlaylist,
                      ),
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar(bool isDataTab, List<LoopItem> items) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: landscape ? 44 : null,
      title: Image.asset(
        'assets/images/logo.png',
        height: landscape ? 22 : 30,
        fit: BoxFit.contain,
      ),
      centerTitle: false,
      actions: [
        if (isDataTab) ...[
          IconButton(
            icon: Icon(_viewModeIcon),
            onPressed: _cycleViewMode,
            tooltip: _viewModeTooltip,
          ),
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.checklist, size: AppIconSizes.ml),
              onPressed: _enterSelectMode,
              tooltip: '複数選択',
            ),
        ],
        IconButton(
          icon: const Icon(Icons.settings, size: AppIconSizes.ml),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
          tooltip: '設定',
        ),
      ],
    );
  }

  /// 複数選択中の操作バー（タブと同じ場所にガラスの板で出す）
  Widget _buildSelectionBar(List<LoopItem> items) {
    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSizes.md),
            tooltip: '選択をやめる',
            onPressed: _clearSelection,
          ),
          Text('${_selectedIds.length} 件選択',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
          const Spacer(),
          _selectionAction(
              Icons.playlist_add, 'PL追加', _showAddToPlaylistSheet),
          _selectionAction(
              Icons.new_label, 'タグ', _showBulkTagSheet),
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
    // 押せる範囲を 44px 以上にし、押した波紋も出す（以前は GestureDetector で 34px・9px の文字）
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: AppIconSizes.md, color: color),
            Text(label,
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                    fontSize: 11,
                    color: color ??
                        Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7))),
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
            const Icon(Icons.check, size: AppIconSizes.sm)
          else
            const SizedBox(width: AppIconSizes.sm),
          const SizedBox(width: AppSpacing.md),
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }

  // === タグフィルターバー ===

  /// 3ステートタグフィルター: null→true(含む)→false(除外)→null
  void _cycleTagFilter(
      Map<String, bool?> selected, String id, void Function(void Function()) setSheetState) {
    setSheetState(() {
      final current = selected[id];
      if (current == null) {
        selected[id] = true;   // off → 含む
      } else if (current) {
        selected[id] = false;  // 含む → 除外
      } else {
        selected.remove(id);   // 除外 → off
      }
    });
    final result = <String, bool>{};
    for (final e in selected.entries) {
      if (e.value != null) result[e.key] = e.value!;
    }
    ref.read(tagFilterProvider.notifier).state = result;
  }

  Widget _buildTagFilterTile({
    required String id,
    required String title,
    required Map<String, bool?> selected,
    required void Function(void Function()) setSheetState,
    Widget? leading,
  }) {
    final state = selected[id]; // null=off, true=含む, false=除外
    final Icon icon;
    final Color? titleColor;
    if (state == true) {
      icon = const Icon(Icons.check_circle, color: AppTheme.accentGreen, size: AppIconSizes.md);
      titleColor = null;
    } else if (state == false) {
      icon = Icon(Icons.remove_circle, color: AppTheme.accentRed, size: AppIconSizes.md);
      titleColor = AppTheme.accentRed;
    } else {
      icon = Icon(Icons.radio_button_unchecked, color: AppTheme.muted(context), size: AppIconSizes.md);
      titleColor = null;
    }

    return ListTile(
      leading: leading,
      title: Text(
        title,
        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
          color: titleColor,
          decoration: state == false ? TextDecoration.lineThrough : null,
        ),
      ),
      trailing: icon,
      onTap: () => _cycleTagFilter(selected, id, setSheetState),
    );
  }

  Widget _buildTagFilterButton(List<Tag> tags, Map<String, bool> filterTagIds) {
    const untaggedId = '__untagged__';
    final active = filterTagIds.isNotEmpty;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GlassPill(
          active: active,
          tooltip: 'タグフィルター',
          padding: const EdgeInsets.all(10),
          child: Icon(Icons.filter_alt_outlined,
              size: AppIconSizes.md,
              color: active ? AppTheme.accentGreen : null),
          onTap: () {
            final selected = Map<String, bool?>.from(filterTagIds);
            _showSheet(builder: (ctx) => StatefulBuilder(
                builder: (ctx, setSheetState) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
                        child: Row(
                          children: [
                            Text('タグフィルター',
                                style: Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            if (selected.isNotEmpty)
                              TextButton(
                                onPressed: () {
                                  ref.read(tagFilterProvider.notifier)
                                      .state = {};
                                  Navigator.pop(ctx);
                                },
                                child: Text('クリア',
                                    style: Theme.of(context).textTheme.bodyMedium),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: AppTheme.accentGreen, size: AppIconSizes.xs),
                            Text(' 含む', style: Theme.of(context).textTheme.labelSmall),
                            const SizedBox(width: AppSpacing.lg),
                            Icon(Icons.remove_circle, color: AppTheme.accentRed, size: AppIconSizes.xs),
                            Text(' 除外', style: Theme.of(context).textTheme.labelSmall),
                            const SizedBox(width: AppSpacing.lg),
                            Icon(Icons.radio_button_unchecked, color: AppTheme.muted(context), size: AppIconSizes.xs),
                            Text(' なし', style: Theme.of(context).textTheme.labelSmall),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      const Divider(height: 1),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            _buildTagFilterTile(
                              id: untaggedId,
                              title: '未分類',
                              selected: selected,
                              setSheetState: setSheetState,
                              leading: const Icon(Icons.label_off, size: AppIconSizes.md),
                            ),
                            for (final tag in tags)
                              _buildTagFilterTile(
                                id: tag.id,
                                title: tag.name,
                                selected: selected,
                                setSheetState: setSheetState,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        if (active)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.xs),
              decoration: const BoxDecoration(
                color: AppTheme.accentGreen,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${filterTagIds.length}',
                style: Theme.of(context).textTheme.labelSmall!.copyWith(color: Colors.black),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFilterChip(Tag tag, bool isInclude) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: TagChip(
        tag: tag,
        excluded: !isInclude,
        onDeleted: () {
          ref.read(tagFilterProvider.notifier).update((s) {
            final next = Map<String, bool>.from(s);
            next.remove(tag.id);
            return next;
          });
        },
      ),
    );
  }

  /// 絞り込み中のタグ（× で外す）と「クリア」
  Widget _buildSelectedTagBar(List<Tag> tags, Map<String, bool> filterTagIds) {
    const untaggedId = '__untagged__';
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 6, AppSpacing.sm, 6),
              children: [
                if (filterTagIds.containsKey(untaggedId))
                  _buildFilterChip(
                    Tag(id: untaggedId, name: '未分類'),
                    filterTagIds[untaggedId]!,
                  ),
                for (final tag in tags)
                  if (filterTagIds.containsKey(tag.id))
                    _buildFilterChip(tag, filterTagIds[tag.id]!),
              ],
            ),
          ),
          TextButton(
            onPressed: () => ref.read(tagFilterProvider.notifier).state = {},
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            ),
            child: Text('クリア',
                style: Theme.of(context).textTheme.labelSmall!
                    .copyWith(color: AppTheme.accentGreen)),
          ),
        ],
      ),
    );
  }

  // === Items view ===

  Widget _buildItemsView(List<LoopItem> items, List<Tag> tags) {
    return switch (_viewMode) {
      _ViewMode.list => _buildListView(items, tags),
      // サムネ + 曲名 + 情報 + タグが収まる高さ（ガラス面の余白ぶん縦長）
      _ViewMode.grid2 => _buildGridView(items, tags,
          maxExtent: 220, ratio: 16 / 15.5, compact: false),
      _ViewMode.grid4 => _buildGridView(items, tags,
          maxExtent: 120, ratio: 16 / 11, compact: true),
    };
  }

  // === Grid view ===

  Widget _buildGridView(
      List<LoopItem> items, List<Tag> tags,
      {required double maxExtent, required double ratio, required bool compact}) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    // 幅に応じて列数を自動算出（横画面・タブレットで列が増える）
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 80 + bottomPad),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: ratio,
        crossAxisSpacing: compact ? AppSpacing.sm : AppSpacing.md + 2,
        mainAxisSpacing: compact ? AppSpacing.sm : AppSpacing.md + 2,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) =>
          _buildCard(items[i], tags, compact: compact),
    );
  }

  /// グリッドのカード（ガラス面）。サムネ・曲名・区間/メモ・タグ。
  /// 選択中は緑の薄い面 + チェック
  Widget _buildCard(LoopItem item, List<Tag> tags, {bool compact = false}) {
    final selected = _selectedIds.contains(item.id);
    final pad = compact ? 3.0 : AppSpacing.md;
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 6 : 10),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ItemThumbnail(
                item: item,
                heroTag: 'thumb_${item.id}',
                iconSize: _viewMode == _ViewMode.grid4 ? AppIconSizes.s : null),
            // 字幕バッジ
            if (item.hasSubtitles == true)
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: AppRadius.borderXs,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.subtitles, size: 12, color: Colors.white70),
                      SizedBox(width: 2),
                      Text('CC', style: TextStyle(fontSize: 11, color: Colors.white70)),
                    ],
                  ),
                ),
              ),
            // オフライン保存バッジ
            if (item.isCached)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: AppTheme.accentGreen.withValues(alpha: 0.9),
                    borderRadius: AppRadius.borderSm,
                  ),
                  child: const Icon(Icons.offline_pin,
                      size: 11, color: AppTheme.darkBackground),
                ),
              ),
            if (item.isFetching || item.hasError) _buildStatusOverlay(item),
            if (selected)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.check,
                      size: AppIconSizes.xs, color: AppTheme.darkBackground),
                ),
              ),
            if (_isSelecting && !selected)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white70, width: 2),
                  ),
                  width: 20,
                  height: 20,
                ),
              ),
          ],
        ),
      ),
    );

    return GlassSurface(
      radius: compact ? 10 : 16,
      padding: EdgeInsets.all(pad),
      tint: selected ? AppTheme.accentGreen.withValues(alpha: 0.15) : null,
      onTap: () => _openDetail(item),
      onLongPress: () => _startSelect(item),
      child: compact
          ? thumb
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                thumb,
                const SizedBox(height: AppSpacing.sm),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (item.isReady) ...[
                  if (_buildCardInfoText(item) case final info?)
                    Text(
                      info,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
                if (item.tagIds.isNotEmpty) ...[
                  const Spacer(),
                  _buildTagChips(item, tags, tiny: true),
                ],
              ],
            ),
    );
  }

  /// カードの 2 行目: BPM・キー・区間数（無ければメモ）
  String? _buildCardInfoText(LoopItem item) {
    final parts = <String>[
      ...item.musicInfoParts,
      if (item.effectiveRegions.any((r) => r.hasPoints))
        '区間 ${item.effectiveRegions.where((r) => r.hasPoints).length}',
    ];
    if (parts.isNotEmpty) return parts.join('  ·  ');
    if (item.memo != null && item.memo!.isNotEmpty) return item.memo;
    return null;
  }

  Widget _buildTagChips(LoopItem item, List<Tag> tags, {bool tiny = false}) {
    final itemTags = tags.where((t) => item.tagIds.contains(t.id)).toList();
    if (itemTags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: 2,
      children: [for (final t in itemTags) TagChip(tag: t, small: tiny)],
    );
  }

  /// 一覧（リスト表示・タグ・プレイリスト）を 1 枚のガラス面にまとめる。
  /// 中の ListView は FAB とミニプレイヤーのぶん下に余白を取る
  Widget _listSurface({required Widget child}) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return GlassSurface(
      margin: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, bottomPad + AppSpacing.lg),
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
    );
  }

  // === List view ===

  Widget _buildListView(List<LoopItem> items, List<Tag> tags) {
    return _listSurface(
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 80),
        itemCount: items.length,
        itemBuilder: (context, i) => _buildListTile(items[i], tags),
      ),
    );
  }

  Widget _buildListTile(LoopItem item, List<Tag> tags) {
    final selected = _selectedIds.contains(item.id);
    return ListTile(
      selected: selected,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSelecting)
            Checkbox(
              value: selected,
              onChanged: (_) => _toggleSelect(item),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ClipRRect(
            borderRadius: AppRadius.borderXs,
            child: SizedBox(
              width: 64,
              height: 36,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ItemThumbnail(item: item, heroTag: 'thumb_${item.id}'),
                  if (item.isFetching)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                        child: SizedBox(
                          width: AppIconSizes.s,
                          height: AppIconSizes.s,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                    ),
                  if (item.hasError)
                    Container(
                      color: Colors.black54,
                      child: const Icon(Icons.error_outline,
                          size: AppIconSizes.sm, color: Colors.orange),
                    ),
                  if (item.hasSubtitles == true)
                    const Positioned(
                      left: 2,
                      bottom: 2,
                      child: Icon(Icons.subtitles, size: 10, color: Colors.white70),
                    ),
                  if (item.isCached)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Icon(Icons.offline_pin,
                          size: 11, color: AppTheme.accentGreen),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      title: Text(
        item.isFetching ? 'データ取得中...' : item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: item.isFetching
            ? Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppTheme.muted(context))
            : Theme.of(context).textTheme.bodyLarge,
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
    final confirmed = await AppDialogs.confirmDelete(context,
        message: '「${item.title}」を削除しますか？');
    if (confirmed) {
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
    final aStr = TimeUtils.formatShortMs(first.pointAMs);
    final bStr = TimeUtils.formatShortMs(first.pointBMs);
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
      return Text('情報を取得中...',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppTheme.muted(context)));
    }
    if (item.hasError) {
      return Text('取得失敗（タップで操作）',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.orange.shade300));
    }

    final parts = <Widget>[];
    final info = <String>[];
    final regionInfo = _buildRegionInfoText(item);
    if (regionInfo != null) info.add(regionInfo);
    if (item.speed != 1.0) info.add('${item.speed}x');
    if (item.playCount > 0) info.add('${item.playCount}回');
    info.addAll(item.musicInfoParts);
    if (item.memo != null && item.memo!.isNotEmpty) info.add(item.memo!);
    if (info.isNotEmpty) {
      parts.add(Text(info.join('  |  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppTheme.muted(context))));
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
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: AppIconSizes.lg,
                    height: AppIconSizes.lg,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text('取得中...',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white)),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.orange, size: AppIconSizes.xl),
                  const SizedBox(height: AppSpacing.xs),
                  Text('取得失敗',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.orange.shade300)),
                ],
              ),
      ),
    );
  }

  // === Tag Manager Tab ===

  Widget _buildTagManagerTab(List<Tag> tags, List<LoopItem> allItems) {
    if (tags.isEmpty) {
      return _buildEmpty(Icons.label_outline, 'タグがありません', '＋ ボタンで作成');
    }

    return _listSurface(
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 80),
        itemCount: tags.length,
        itemBuilder: (context, i) {
          final tag = tags[i];
          final count =
              allItems.where((item) => item.tagIds.contains(tag.id)).length;

          return ListTile(
            leading: Container(
              width: AppIconSizes.lg,
              height: AppIconSizes.lg,
              decoration: BoxDecoration(
                color: tag.color.withValues(alpha: 0.25),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.label, size: AppIconSizes.xs, color: tag.color),
            ),
            title: Text(tag.name, style: Theme.of(context).textTheme.bodyLarge),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$count 曲',
                    style: Theme.of(context).textTheme.bodySmall),
                IconButton(
                  icon: const Icon(Icons.more_vert, size: AppIconSizes.md),
                  tooltip: 'メニュー',
                  onPressed: () => _showTagMenu(tag),
                ),
              ],
            ),
            onTap: () {
              // 曲リストタブに移動してこのタグでフィルター
              ref.read(tagFilterProvider.notifier).state = {tag.id: true};
              _tabController.animateTo(1);
            },
            onLongPress: () => _showTagMenu(tag),
          );
        },
      ),
    );
  }

  void _createTagFromTab() async {
    final name = await AppDialogs.prompt(context,
        title: 'タグを作成',
        hintText: 'タグ名',
        confirmLabel: '作成',
        maxLength: AppLimits.tagNameMaxLength);
    if (name == null) return;
    ref.read(tagsProvider.notifier).create(name);
  }

  void _showTagMenu(Tag tag) {
    AppSheets.actions(
      context,
      title: tag.name,
      actions: [
        SheetAction(
          icon: Icons.edit,
          label: '名前を変更',
          onTap: () => _renameTagFromTab(tag),
        ),
        SheetAction(
          icon: Icons.palette_outlined,
          label: '色を変更',
          onTap: () => _showTagColorPicker(tag),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => _deleteTag(tag),
        ),
      ],
    );
  }

  /// 全曲からこのタグが外れて戻せないので、使われている曲数を出して確認する
  Future<void> _deleteTag(Tag tag) async {
    final used = ref
        .read(loopItemsProvider)
        .where((i) => i.tagIds.contains(tag.id))
        .length;
    final ok = await AppDialogs.confirmDelete(context,
        title: 'タグを削除',
        message: used == 0
            ? 'タグ「${tag.name}」を削除しますか？'
            : 'タグ「${tag.name}」を削除しますか？'
                '\n$used 曲からこのタグが外れます（曲は残ります）');
    if (!ok || !mounted) return;
    ref.read(tagFilterProvider.notifier).update(
        (s) => Map<String, bool>.from(s)..remove(tag.id));
    ref.read(tagsProvider.notifier).delete(tag.id);
    ref.read(loopItemsProvider.notifier).removeTagFromAll(tag.id);
  }

  void _showTagColorPicker(Tag tag) {
    _showSheet(builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('「${tag.name}」の色',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xl),
              Wrap(
                spacing: AppSpacing.lg,
                runSpacing: AppSpacing.lg,
                children: [
                  for (var i = 0; i < tagPresetColors.length; i++)
                    GestureDetector(
                      onTap: () {
                        ref.read(tagsProvider.notifier).setColor(tag.id, i);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: tagPresetColors[i],
                          shape: BoxShape.circle,
                          border: tag.colorIndex == i
                              ? Border.all(color: Colors.white, width: 3)
                              : null,
                        ),
                        child: i == 0
                            ? Center(
                                child: Text('D',
                                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white)))
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ),
      ),
    );
  }

  void _renameTagFromTab(Tag tag) async {
    final name = await AppDialogs.prompt(context,
        title: 'タグ名変更',
        initialValue: tag.name,
        hintText: 'タグ名',
        maxLength: AppLimits.tagNameMaxLength);
    if (name == null) return;
    ref.read(tagsProvider.notifier).rename(tag.id, name);
  }

  // === Playlist ===

  Widget _buildPlaylistList(List<Playlist> playlists) {
    final items = ref.watch(loopItemsProvider);
    return _listSurface(
      child: ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 80),
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final pl = playlists[i];
        final count = pl.itemIds
            .where((id) => items.any((item) => item.id == id))
            .length;
        final thumbItemId = pl.effectiveThumbnailItemId;
        final thumbItem = thumbItemId != null
            ? items.where((item) => item.id == thumbItemId).firstOrNull
            : null;
        return ListTile(
          leading: ClipRRect(
            borderRadius: AppRadius.borderMd,
            child: SizedBox(
              width: 56,
              height: 56,
              child: thumbItem != null
                  ? ItemThumbnail(item: thumbItem)
                  : Container(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.08),
                      child: Icon(Icons.playlist_play,
                          color: AppTheme.muted(context)),
                    ),
            ),
          ),
          title: Text(pl.name),
          subtitle: Text('$count 曲',
              style: Theme.of(context).textTheme.bodySmall),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (count > 0)
                GreenButton(
                  icon: Icons.play_arrow_rounded,
                  label: '再生',
                  size: 34,
                  onPressed: () => _playPlaylist(pl, items),
                ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'duplicate') _duplicatePlaylist(pl);
                  if (v == 'delete') _deletePlaylist(pl);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'duplicate', child: Text('複製')),
                  const PopupMenuItem(
                      value: 'delete',
                      child: Text('削除',
                          style: TextStyle(color: Colors.red))),
                ],
              ),
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
      ),
    );
  }

  // === Empty / Thumbnail ===

  Widget _buildEmpty(IconData icon, String title, String sub) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 空のときの案内。以前は 0.3 で読めないほど薄かった
          Icon(icon,
              size: AppIconSizes.huge,
              color: AppTheme.muted(context, alpha: 0.4)),
          const SizedBox(height: AppSpacing.lg),
          Text(title,
              style: TextStyle(color: AppTheme.muted(context, alpha: 0.75))),
          const SizedBox(height: AppSpacing.xs),
          Text(sub,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: AppTheme.muted(context, alpha: 0.6))),
        ],
      ),
    );
  }

  /// [hero] は詳細画面へ遷移するアイテムカードでのみ true にする。
  /// プレイリストのサムネにも付けると、同じ曲をサムネにしたプレイリストと
  /// そのアイテム自身が同一画面に並んだときにHeroタグが重複してクラッシュする。
}

// ============================================================
// 複数選択タグ操作シート
// ============================================================

class _BulkTagSheet extends StatefulWidget {
  final List<Tag> tags;
  final List<LoopItem> selectedItems;
  final List<LoopItem> allItems;
  final void Function(String tagId) onAddTag;
  final void Function(String tagId) onRemoveTag;
  final VoidCallback onClearTags;
  final Future<Tag> Function(String name) onCreateTag;

  const _BulkTagSheet({
    required this.tags,
    required this.selectedItems,
    required this.allItems,
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
  // タグごとの適用状態: true=全員付与, false=全員なし, null=初期（実データ参照）
  final Map<String, bool> _tagState = {};

  @override
  void initState() {
    super.initState();
    _tags = List.from(widget.tags);
  }

  /// 表示用の値: true=✓, false=□, null=ー
  bool? _displayValue(String tagId) {
    if (_tagState.containsKey(tagId)) return _tagState[tagId];
    final all = widget.selectedItems.every((i) => i.tagIds.contains(tagId));
    if (all) return true;
    final some = widget.selectedItems.any((i) => i.tagIds.contains(tagId));
    if (some) return null;
    return false;
  }

  void _showNewTagInput() async {
    final name = await AppDialogs.prompt(context,
        title: '新しいタグ',
        hintText: 'タグ名',
        confirmLabel: '作成',
        maxLength: AppLimits.tagNameMaxLength);
    if (name != null) {
      final tag = await widget.onCreateTag(name);
      widget.onAddTag(tag.id);
      setState(() {
        _tags.add(tag);
        _tagState[tag.id] = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
            child: Row(
              children: [
                Text(
                  'タグ（${widget.selectedItems.length}件に適用）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (_tags.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      final ok = await AppDialogs.confirm(context,
                          title: 'タグをすべて解除',
                          message:
                              '選んだ ${widget.selectedItems.length} 件からタグをすべて外しますか？',
                          confirmLabel: '解除',
                          destructive: true);
                      if (!ok || !mounted) return;
                      widget.onClearTags();
                      setState(() {
                        for (final t in _tags) {
                          _tagState[t.id] = false;
                        }
                      });
                    },
                    child: Text('すべて解除',
                        style: Theme.of(context).textTheme.labelMedium),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_tags.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Text('タグがありません',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.muted(context))),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final tag in _tags)
                  CheckboxListTile(
                    title: Text(tag.name,
                        style: Theme.of(context).textTheme.bodyLarge),
                    subtitle: Text(
                      '${widget.allItems.where((i) => i.tagIds.contains(tag.id)).length} 曲',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppTheme.muted(context)),
                    ),
                    secondary: Icon(Icons.label,
                        size: AppIconSizes.md,
                        color: tag.color),
                    value: _displayValue(tag.id),
                    tristate: true,
                    onChanged: (_) {
                      if (_displayValue(tag.id) == true) {
                        // ✓ → 全外し
                        widget.onRemoveTag(tag.id);
                        setState(() => _tagState[tag.id] = false);
                      } else {
                        // □ or ー → 全付け
                        widget.onAddTag(tag.id);
                        setState(() => _tagState[tag.id] = true);
                      }
                    },
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add, size: AppIconSizes.md),
            title: Text('新しいタグを作成',
                style: Theme.of(context).textTheme.bodyLarge),
            onTap: _showNewTagInput,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

// ============================================================
// YouTubeプレイリスト動画選択ページ
// ============================================================

class _PlaylistVideoSelectPage extends StatefulWidget {
  final List<PlaylistVideoInfo> videos;
  final Set<String> duplicateIds;
  final String playlistTitle;
  final void Function(List<PlaylistVideoInfo> selected) onConfirm;

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
        .where((v) => !widget.duplicateIds.contains(v.id))
        .map((v) => v.id)
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selected.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlistTitle,
            style: Theme.of(context).textTheme.bodyLarge,
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
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
            child: Row(
              children: [
                Text('${widget.videos.length}件中 $selectedCount件選択',
                    style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _selected =
                        widget.videos.map((v) => v.id).toSet();
                  }),
                  child: Text('すべて選択', style: Theme.of(context).textTheme.labelMedium),
                ),
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: Text('すべて解除', style: Theme.of(context).textTheme.labelMedium),
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
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  subtitle: isDuplicate
                      ? Text('登録済み',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Colors.orange))
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
