import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/item_filter.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
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

/// ホーム。3 つのタブ（タグ / 曲 / プレイリスト）と、曲タブの検索・絞り込み・並び替え。
/// 「表示」（リスト / グリッド）と「複数選択」はどのタブにもある（選べるものはタブごと:
/// タグは色変更と削除、曲はプレイリスト追加・タグ・削除、プレイリストは複製と削除）。
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
  // 2 = プレイリスト（switch の既定）

  late final TabController _tabController;
  int get _tab => _tabController.index;

  // 表示モード（タブごと）
  ItemViewMode _itemViewMode = ItemViewMode.grid2;
  bool _tagGrid = false;
  bool _playlistGrid = false;

  // 複数選択（いま開いているタブのもの。タブを移ると解除）
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
    _tabController.addListener(() {
      // 選択はタブごとなので、移ったら解除（選択中はスワイプできないが、戻るで解除し
      // 忘れた場合などの保険）
      if (_tabController.indexIsChanging && _isSelecting) {
        _selectMode = false;
        _selectedIds.clear();
      }
      setState(() {});
    });
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
      _toggleSelectId(item.id);
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

  // --- 複数選択（タブ共通） ---

  void _toggleSelectId(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  void _startSelectId(String id) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(id);
    });
  }

  /// AppBar の「選択」から。長押しを知らなくても入れるように
  void _enterSelectMode() => setState(() => _selectMode = true);

  void _selectAll(Iterable<String> ids) {
    setState(() => _selectedIds.addAll(ids));
  }

  void _clearSelection() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelectedItems() async {
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
    final playlists = ref.watch(playlistsProvider);
    final filterTagIds = ref.watch(tagFilterProvider);

    final items = ItemFilter.apply(allItems,
        tagFilter: filterTagIds, query: _searchQuery, sort: _sortMode);

    // いまのタブで選べるものの ID（「全選択」と AppBar の「選択」の表示に使う）
    final selectableIds = switch (_tab) {
      _tabTags => tags.map((t) => t.id),
      _tabItems => items.map((i) => i.id),
      _ => playlists.map((p) => p.id),
    };

    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _clearSelection();
      },
      child: GlassScaffold(
        toolbarHeight: landscape ? 44 : null,
        title: Image.asset(
          'assets/images/logo.png',
          height: landscape ? 22 : 30,
          fit: BoxFit.contain,
        ),
        actions: _buildAppBarActions(canSelect: selectableIds.isNotEmpty),
        // 本文の上端は bodyBuilder の context から（AppBar の高さが入る）
        bodyBuilder: (bodyContext) => SafeArea(
              top: false,
              bottom: false,
              child: Stack(
                children: [
                  GestureDetector(
                    onTap: () => FocusScope.of(context).unfocus(),
                    behavior: HitTestBehavior.translucent,
                    child: Column(
                        children: [
                          SizedBox(
                              height: MediaQuery.paddingOf(bodyContext).top +
                                  AppSpacing.xs),
                          // タブ（選択中は操作バー）: ガラスのセグメント
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg),
                            child: _isSelecting
                                ? _buildSelectionBar(selectableIds)
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
                                  grid: _tagGrid,
                                  selecting: _isSelecting,
                                  selectedIds: _selectedIds,
                                  onToggleSelect: (t) => _toggleSelectId(t.id),
                                  onLongPress: (t) => _startSelectId(t.id),
                                  onTagTap: (tag) {
                                    // 曲タブに移動してこのタグでフィルター
                                    ref.read(tagFilterProvider.notifier).state = {
                                      tag.id: true
                                    };
                                    _tabController.animateTo(_tabItems);
                                  },
                                ),
                                _buildItemsTab(items, filterTagIds),
                                PlaylistTab(
                                  grid: _playlistGrid,
                                  selecting: _isSelecting,
                                  selectedIds: _selectedIds,
                                  onToggleSelect: (p) => _toggleSelectId(p.id),
                                  onLongPress: (p) => _startSelectId(p.id),
                                ),
                              ],
                            ),
                          ),
                        ],
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
        // キーボードが出ている間は FAB を出さない。出したままだとキーボードの上に
        // 逃げ、閉じるときは先に定位置へ飛んでキーボードの裏に隠れ、キーボードが
        // 下がりきってから下から現れる、という動きに見える
        floatingActionButton: _isSelecting || keyboardOpen ? null : _buildFab(),
      ),
    );
  }

  Widget _buildFab() {
    return switch (_tab) {
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
  Widget _buildItemsTab(List<LoopItem> items, Map<String, bool> filterTagIds) {
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
                  viewMode: _itemViewMode,
                  selectedIds: _selectedIds,
                  selecting: _isSelecting,
                  onOpen: _openDetail,
                  onLongPress: (item) => _startSelectId(item.id),
                  onToggleSelect: (item) => _toggleSelectId(item.id),
                  onDelete: _deleteItem,
                  onRetry: (item) =>
                      ref.read(loopItemsProvider.notifier).retryFetch(item),
                ),
        ),
      ],
    );
  }

  /// AppBar: ロゴ / 表示切替 / 複数選択 / 設定。表示と選択はどのタブにも出す
  /// AppBar の右側: 表示の切り替え（タブごと）・複数選択・設定
  List<Widget> _buildAppBarActions({required bool canSelect}) {
    final (IconData viewIcon, String viewTooltip, VoidCallback onView) =
        switch (_tab) {
      _tabTags => (
          _tagGrid ? Icons.grid_view : Icons.view_list,
          _tagGrid ? 'リスト表示へ' : 'グリッド表示へ',
          () => setState(() => _tagGrid = !_tagGrid),
        ),
      _tabItems => (
          _itemViewMode.icon,
          _itemViewMode.nextTooltip,
          () => setState(() => _itemViewMode = _itemViewMode.next),
        ),
      _ => (
          _playlistGrid ? Icons.grid_view : Icons.view_list,
          _playlistGrid ? 'リスト表示へ' : 'グリッド表示へ',
          () => setState(() => _playlistGrid = !_playlistGrid),
        ),
    };
    return [
      IconButton(icon: Icon(viewIcon), onPressed: onView, tooltip: viewTooltip),
      if (canSelect)
        IconButton(
          icon: const Icon(Icons.checklist, size: AppIconSizes.ml),
          onPressed: _enterSelectMode,
          tooltip: '複数選択',
        ),
      IconButton(
        icon: const Icon(Icons.settings, size: AppIconSizes.ml),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        ),
        tooltip: '設定',
      ),
    ];
  }

  /// 複数選択中の操作バー（タブと同じ場所にガラスの板で出す）。操作はタブごと
  Widget _buildSelectionBar(Iterable<String> selectableIds) {
    List<Tag> selectedTags() =>
        ref.read(tagsProvider).where((t) => _selectedIds.contains(t.id)).toList();
    List<Playlist> selectedPlaylists() => ref
        .read(playlistsProvider)
        .where((p) => _selectedIds.contains(p.id))
        .toList();

    final actions = switch (_tab) {
      _tabTags => [
          _selectionAction(Icons.palette_outlined, '色', () async {
            await TagManagerTab.recolorTags(context, ref, selectedTags());
          }),
          _selectionAction(Icons.select_all, '全選択', () => _selectAll(selectableIds)),
          _selectionAction(Icons.delete_outline, '削除', () async {
            if (await TagManagerTab.deleteTags(context, ref, selectedTags())) {
              _clearSelection();
            }
          }, color: Colors.red),
        ],
      _tabItems => [
          _selectionAction(Icons.playlist_add, 'PL追加', _showAddToPlaylistSheet),
          _selectionAction(Icons.new_label, 'タグ', _showBulkTagSheet),
          _selectionAction(Icons.select_all, '全選択', () => _selectAll(selectableIds)),
          _selectionAction(Icons.delete_outline, '削除', _deleteSelectedItems,
              color: Colors.red),
        ],
      _ => [
          _selectionAction(Icons.copy_outlined, '複製', () async {
            await PlaylistTab.duplicatePlaylists(context, ref, selectedPlaylists());
            _clearSelection();
          }),
          _selectionAction(Icons.select_all, '全選択', () => _selectAll(selectableIds)),
          _selectionAction(Icons.delete_outline, '削除', () async {
            if (await PlaylistTab.deletePlaylists(
                context, ref, selectedPlaylists())) {
              _clearSelection();
            }
          }, color: Colors.red),
        ],
    };

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
          ...actions,
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
