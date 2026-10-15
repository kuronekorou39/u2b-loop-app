import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/item_filter.dart';
import '../models/loop_item.dart';
import '../providers/data_provider.dart';
import '../providers/easter_egg_provider.dart';
import '../widgets/bulk_tag_sheet.dart';
import '../widgets/empty_hint.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/loading_animations/loading_animation.dart';
import '../widgets/loading_animations/loading_animation_widget.dart';
import 'detail_screen.dart';
import 'home/add_to_playlist_sheet.dart';
import 'home/item_views.dart';
import 'home/playlist_tab.dart';
import 'home/tag_filter_bar.dart';
import 'home/tag_manager_tab.dart';
import 'home/youtube_import_flow.dart';
import 'settings_screen.dart';

/// ホーム。3 つのタブ（タグ / 曲 / プレイリスト）と、曲タブの検索・絞り込み・並び替え・複数選択。
///
/// 中身はタブごとに分かれている: タグ [TagManagerTab]、プレイリスト [PlaylistTab]、
/// 曲の一覧 [ItemCollectionView]、取り込み [YouTubeImportFlow]、
/// 絞り込みの計算 [ItemFilter]。ここに残るのはタブ・選択・検索の状態と AppBar
class ListScreen extends ConsumerStatefulWidget {
  const ListScreen({super.key});

  @override
  ConsumerState<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends ConsumerState<ListScreen>
    with SingleTickerProviderStateMixin {
  static const _tabTags = 0;
  static const _tabItems = 1;

  ItemViewMode _viewMode = ItemViewMode.grid2;
  late final TabController _tabController;

  // 複数選択
  final Set<String> _selectedIds = {};

  /// AppBar の「選択」で入ったとき（まだ何も選んでいなくても選択中として扱う）
  bool _selectMode = false;
  bool get _isSelecting => _selectMode || _selectedIds.isNotEmpty;

  String _searchQuery = '';
  ItemSortMode _sortMode = ItemSortMode.updatedDesc;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(skipTraversal: true);
  bool _matrixActive = false;

  @override
  void initState() {
    super.initState();
    _tabController =
        TabController(length: 3, vsync: this, initialIndex: _tabItems);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
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

  Future<void> _deleteItem(LoopItem item) async {
    final confirmed = await AppDialogs.confirmDelete(context,
        message: '「${item.title}」を削除しますか？');
    if (confirmed) {
      ref.read(loopItemsProvider.notifier).delete(item.id);
    }
  }

  // --- 複数選択 ---

  void _toggleSelect(LoopItem item) {
    setState(() {
      if (!_selectedIds.remove(item.id)) _selectedIds.add(item.id);
    });
  }

  void _startSelect(LoopItem item) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(item.id);
    });
  }

  /// AppBar の「選択」から。長押しを知らなくても入れるように
  void _enterSelectMode() => setState(() => _selectMode = true);

  void _selectAll(List<LoopItem> items) {
    setState(() => _selectedIds.addAll(items.map((i) => i.id)));
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
    if (!confirmed) return;
    final ids = Set<String>.from(_selectedIds);
    _clearSelection();
    for (final id in ids) {
      await ref.read(loopItemsProvider.notifier).delete(id);
    }
  }

  void _showBulkTagSheet() {
    _searchFocusNode.unfocus();
    BulkTagSheet.show(context, ref, _selectedIds.toList())
        .then((_) => _searchFocusNode.unfocus());
  }

  void _showAddToPlaylistSheet() {
    _searchFocusNode.unfocus();
    showAddItemsToPlaylistSheet(
      context,
      ref,
      itemIds: _selectedIds.toList(),
      onAdded: _clearSelection,
    );
  }

  // === Build ===

  @override
  Widget build(BuildContext context) {
    final allItems = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);
    final filterTagIds = ref.watch(tagFilterProvider);

    final isItemsTab = _tabController.index == _tabItems;
    final items = ItemFilter.apply(allItems,
        tagFilter: filterTagIds, query: _searchQuery, sort: _sortMode);

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
        appBar: _buildAppBar(isItemsTab, items),
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
                    child: Builder(
                      builder: (bodyContext) => Column(
                        children: [
                          SizedBox(
                              height: MediaQuery.paddingOf(bodyContext).top +
                                  AppSpacing.xs),
                          // タブ（選択中は操作バー）: ガラスのセグメント
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg),
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
                              physics: _isSelecting
                                  ? const NeverScrollableScrollPhysics()
                                  : null,
                              children: [
                                TagManagerTab(
                                  onTagTap: (tag) {
                                    // 曲タブに移動してこのタグでフィルター
                                    ref.read(tagFilterProvider.notifier).state = {
                                      tag.id: true
                                    };
                                    _tabController.animateTo(_tabItems);
                                  },
                                ),
                                _buildItemsTab(items, tags, filterTagIds),
                                const PlaylistTab(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_matrixActive)
                    const Positioned.fill(
                      child: IgnorePointer(
                        child: LoadingAnimationView(
                            type: LoadingAnimationType.matrix),
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
        floatingActionButton: _isSelecting || keyboardOpen ? null : _buildFab(),
      ),
    );
  }

  Widget _buildFab() {
    return switch (_tabController.index) {
      _tabTags => GreenButton(
          icon: Icons.new_label,
          size: 56,
          tooltip: 'タグを作成',
          onPressed: () => TagManagerTab.createTag(context, ref),
        ),
      _tabItems => GreenButton(
          icon: Icons.add,
          size: 56,
          tooltip: '追加',
          onPressed: () =>
              YouTubeImportFlow(context: context, ref: ref).showAddDialog(),
        ),
      _ => GreenButton(
          icon: Icons.playlist_add,
          size: 56,
          tooltip: 'プレイリストを作成',
          onPressed: () => PlaylistTab.createPlaylist(context, ref),
        ),
    };
  }

  /// 曲タブ: 検索・絞り込み・並び替えの行 + 一覧
  Widget _buildItemsTab(
      List<LoopItem> items, List<dynamic> tags, Map<String, bool> filterTagIds) {
    final allTags = ref.watch(tagsProvider);
    return Column(
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
                    if (v.toLowerCase() == 'matrix') _triggerMatrixEasterEgg();
                  },
                  onClear: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
              ),
              if (allTags.isNotEmpty) ...[
                const SizedBox(width: AppSpacing.md),
                TagFilterButton(
                    tags: allTags, onClosed: _searchFocusNode.unfocus),
              ],
              const SizedBox(width: AppSpacing.md),
              PopupMenuButton<ItemSortMode>(
                tooltip: '並び替え',
                onSelected: (mode) => setState(() => _sortMode = mode),
                itemBuilder: (_) => [
                  for (final mode in ItemSortMode.values)
                    PopupMenuItem(
                      value: mode,
                      child: Row(
                        children: [
                          if (_sortMode == mode)
                            const Icon(Icons.check, size: AppIconSizes.sm)
                          else
                            const SizedBox(width: AppIconSizes.sm),
                          const SizedBox(width: AppSpacing.md),
                          Text(mode.label,
                              style: Theme.of(context).textTheme.bodyLarge),
                        ],
                      ),
                    ),
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
        if (filterTagIds.isNotEmpty) SelectedTagBar(tags: allTags),
        Expanded(
          child: items.isEmpty
              ? EmptyHint(
                  icon: Icons.music_note_outlined,
                  title: filterTagIds.isNotEmpty
                      ? '該当するデータがありません'
                      : 'データがありません',
                  subtitle: filterTagIds.isNotEmpty
                      ? 'フィルターを変更してください'
                      : '＋ ボタンで追加',
                )
              : ItemCollectionView(
                  items: items,
                  tags: allTags,
                  viewMode: _viewMode,
                  selectedIds: _selectedIds,
                  selecting: _isSelecting,
                  onOpen: _openDetail,
                  onLongPress: _startSelect,
                  onToggleSelect: _toggleSelect,
                  onDelete: _deleteItem,
                  onRetry: (item) =>
                      ref.read(loopItemsProvider.notifier).retryFetch(item),
                ),
        ),
      ],
    );
  }

  PreferredSizeWidget _buildAppBar(bool isItemsTab, List<LoopItem> items) {
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
        if (isItemsTab) ...[
          IconButton(
            icon: Icon(_viewMode.icon),
            onPressed: () => setState(() => _viewMode = _viewMode.next),
            tooltip: _viewMode.nextTooltip,
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
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSizes.md),
            tooltip: '選択をやめる',
            onPressed: _clearSelection,
          ),
          Text('${_selectedIds.length} 件選択',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const Spacer(),
          _selectionAction(Icons.playlist_add, 'PL追加', _showAddToPlaylistSheet),
          _selectionAction(Icons.new_label, 'タグ', _showBulkTagSheet),
          _selectionAction(Icons.select_all, '全選択', () => _selectAll(items)),
          _selectionAction(Icons.delete_outline, '削除', _deleteSelected,
              color: Colors.red),
        ],
      ),
    );
  }

  Widget _selectionAction(IconData icon, String label, VoidCallback onTap,
      {Color? color}) {
    // 押せる範囲を 44px 以上にし、押した波紋も出す
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
                    color: color ?? AppTheme.muted(context, alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}
