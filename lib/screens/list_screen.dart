import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/item_filter.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import '../widgets/bulk_tag_sheet.dart';
import '../widgets/empty_hint.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
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
/// 絞り込みの計算 [ItemFilter]。ここに残るのはタブ・選択・検索の状態と見出し。
///
/// 見出し（ロゴの行・タブ・曲タブの検索とタグ）は一覧を下へ送ると上へ抜けて隠れ、
/// 戻すと出てくる（横画面だと見出しだけで一覧が 1 行しか見えなかった）。
/// 一覧は見出しの分だけ広がり、指の下の中身は動かさない（[_onScroll]）
class ListScreen extends ConsumerStatefulWidget {
  const ListScreen({super.key});

  @override
  ConsumerState<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends ConsumerState<ListScreen>
    with TickerProviderStateMixin {
  static const _tabTags = 0;
  static const _tabItems = 1;
  // 2 = プレイリスト（switch の既定）

  late final TabController _tabController;
  int get _tab => _tabController.index;

  // 表示モード（タブごと）。次に開いたときも同じ表示にする
  ItemViewMode _itemViewMode = ItemViewMode.fromName(
      AppBoxes.settings.get(SettingsKeys.homeItemView) as String?);
  TagViewMode _tagViewMode = TagViewMode.fromName(
      AppBoxes.settings.get(SettingsKeys.homeTagView) as String?,
      legacyGrid: AppBoxes.settings
          .get(SettingsKeys.homeTagGrid, defaultValue: false) as bool);
  bool _playlistGrid = AppBoxes.settings
      .get(SettingsKeys.homePlaylistGrid, defaultValue: false) as bool;

  void _setItemViewMode(ItemViewMode mode) {
    setState(() => _itemViewMode = mode);
    AppBoxes.settings.put(SettingsKeys.homeItemView, mode.name);
  }

  void _setTagViewMode(TagViewMode mode) {
    setState(() => _tagViewMode = mode);
    AppBoxes.settings.put(SettingsKeys.homeTagView, mode.name);
  }

  void _togglePlaylistGrid() {
    setState(() => _playlistGrid = !_playlistGrid);
    AppBoxes.settings.put(SettingsKeys.homePlaylistGrid, _playlistGrid);
  }

  // 複数選択（いま開いているタブのもの。タブを移ると解除）
  final Set<String> _selectedIds = {};

  /// 選択に入ったまま全部外したとき（まだ何も選んでいなくても選択中として扱う）
  bool _selectMode = false;
  bool get _isSelecting => _selectMode || _selectedIds.isNotEmpty;

  String _searchQuery = '';
  ItemSortMode _sortMode = ItemSortMode.updatedDesc;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(skipTraversal: true);

  // --- 見出しの出し入れ ---

  /// 見出しの隠れている高さ（0 = 全部見えている、[_headerExtent] = 全部隠れた）
  double _headerHidden = 0;

  /// 隠れる部分（ロゴの行から下）の本来の高さ。描画後に測る
  double _headerExtent = 0;
  final _headerKey = GlobalKey();

  /// 指を離したとき途中なら、近い方（出す / 隠す）へ寄せる
  late final AnimationController _headerSnap = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() => setState(() => _headerHidden = _headerSnapTween
        .transform(Curves.easeOutCubic.transform(_headerSnap.value))));
  Tween<double> _headerSnapTween = Tween(begin: 0, end: 0);

  void _animateHeaderTo(double hidden) {
    _headerSnap.stop();
    if ((hidden - _headerHidden).abs() < 0.5) {
      if (hidden != _headerHidden) setState(() => _headerHidden = hidden);
      return;
    }
    _headerSnapTween = Tween(begin: _headerHidden, end: hidden);
    _headerSnap.forward(from: 0);
  }

  /// 一覧のスクロールに合わせて見出しを出し入れする。下へ送ると隠れ、戻すと出る
  /// （一番上でさらに引いても出る）。指で動かしている間は、見出しが縮んだ / 伸びた分だけ
  /// 一覧の位置を直し、中身が指から離れないようにする
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final extent = _headerExtent;
    if (extent <= 0) return false;
    if (n is ScrollStartNotification) {
      _headerSnap.stop();
    } else if (n is ScrollUpdateNotification) {
      final delta = n.scrollDelta ?? 0;
      final ctx = n.context;
      final position = n.dragDetails == null || ctx == null
          ? null
          : Scrollable.maybeOf(ctx)?.position;
      if (delta > 0 && _headerHidden < extent) {
        final c = math.min(delta, extent - _headerHidden);
        setState(() => _headerHidden += c);
        position?.correctPixels(position.pixels - c);
      } else if (delta < 0 && _headerHidden > 0) {
        final c = math.min(-delta, _headerHidden);
        setState(() => _headerHidden -= c);
        position?.correctPixels(position.pixels + c);
      }
    } else if (n is OverscrollNotification &&
        n.overscroll < 0 &&
        _headerHidden > 0) {
      setState(() =>
          _headerHidden = math.max(0, _headerHidden + n.overscroll));
    } else if (n is ScrollEndNotification) {
      if (_headerHidden > 0 && _headerHidden < extent) {
        final hide = _headerHidden > extent / 2 &&
            n.metrics.pixels > n.metrics.minScrollExtent;
        _animateHeaderTo(hide ? extent : 0);
      }
    }
    return false;
  }

  /// 見出しの本来の高さを測る（タブで中身が変わる）
  void _measureHeader() {
    final h = _headerKey.currentContext?.size?.height;
    if (h == null || (h - _headerExtent).abs() < 0.5) return;
    setState(() {
      _headerExtent = h;
      _headerHidden = _headerHidden.clamp(0.0, h);
    });
  }

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
      // タブを移ったら見出しは出す（隠れたままだとタブが押せない）
      if (_headerHidden > 0) _animateHeaderTo(0);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _headerSnap.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // --- アイテム操作 ---

  void _openDetail(LoopItem item) {
    if (_isSelecting) {
      _toggleSelectId(item.id);
      return;
    }
    if (item.isFetching) {
      AppToast.instance.show(
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

    // いまのタブで選べるものの ID（「全選択」に使う）
    final selectableIds = switch (_tab) {
      _tabTags => tags.map((t) => t.id),
      _tabItems => items.map((i) => i.id),
      _ => playlists.map((p) => p.id),
    };

    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final theme = Theme.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureHeader();
    });
    final extent = _headerExtent;
    // 隠れる部分: ロゴの行・タブ（選択中は操作バー）・曲タブの検索とタグ。
    // 横画面は高さが足りないので、ロゴ・タブ・検索・ボタンを 1 行にまとめる
    final tabsOrSelection = SizedBox(
      // 選択に入っても下の一覧が動かないよう、高さを揃える
      height: _topBarHeight,
      child: _isSelecting
          ? _buildSelectionBar(selectableIds)
          : GlassSegmentedTabs(
              controller: _tabController,
              labels: const ['タグ', '曲', 'プレイリスト'],
            ),
    );
    final logo = Image.asset(
      'assets/images/logo.png',
      height: landscape ? 22 : 30,
      fit: BoxFit.contain,
    );
    final collapsible = Column(
      key: _headerKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (landscape) ...[
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xl),
            child: Row(
              children: [
                logo,
                const SizedBox(width: AppSpacing.xl),
                if (_isSelecting)
                  Expanded(child: tabsOrSelection)
                else ...[
                  SizedBox(width: _landscapeTabsWidth, child: tabsOrSelection),
                  const SizedBox(width: AppSpacing.md),
                  if (_tab == _tabItems)
                    Expanded(child: _buildSearchRow(inline: true, tags: tags))
                  else
                    const Spacer(),
                ],
                ..._buildAppBarActions(),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ] else ...[
          AppBar(
            primary: false,
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: logo,
            actions: _buildAppBarActions(),
          ),
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: tabsOrSelection,
          ),
          const SizedBox(height: AppSpacing.md),
          if (_tab == _tabItems) ...[
            _buildSearchRow(),
            // タグがあるあいだは常に出す（選ぶたびに一覧が下がらないように）
            if (tags.isNotEmpty)
              SelectedTagBar(tags: tags, onClosed: _searchFocusNode.unfocus),
          ],
        ],
      ],
    );
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _clearSelection();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: theme.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: GlassScaffold(
          showAppBar: false,
          body: SafeArea(
            top: false,
            bottom: false,
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              behavior: HitTestBehavior.translucent,
              child: Column(
                children: [
                  // 状態バーの分は隠さない
                  SizedBox(height: MediaQuery.paddingOf(context).top),
                  ClipRect(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      heightFactor: extent <= 0
                          ? 1
                          : (1 - _headerHidden / extent).clamp(0.0, 1.0),
                      child: collapsible,
                    ),
                  ),
                  Expanded(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _onScroll,
                      child: TabBarView(
                        controller: _tabController,
                        physics: _isSelecting
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        children: [
                          TagManagerTab(
                            viewMode: _tagViewMode,
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
                  ),
                ],
              ),
            ),
          ),
          // キーボードが出ている間は FAB を出さない。出したままだとキーボードの上に
          // 逃げ、閉じるときは先に定位置へ飛んでキーボードの裏に隠れ、キーボードが
          // 下がりきってから下から現れる、という動きに見える
          floatingActionButton:
              _isSelecting || keyboardOpen ? null : _buildFab(),
        ),
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

  /// 曲タブの一覧（検索・絞り込み・並び替えの行は見出しの中 [_buildSearchRow]）
  Widget _buildItemsTab(List<LoopItem> items, Map<String, bool> filterTagIds) {
    final allTags = ref.watch(tagsProvider);
    return items.isEmpty
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
                );
  }

  /// 横画面の 1 行の見出しで、タブに使う幅
  static const _landscapeTabsWidth = 340.0;

  /// 曲タブの検索・並び替えの行（見出しの中。一覧と一緒に上へ抜ける）。
  /// [inline] は横画面の 1 行に入れるとき（外の余白なし。タグの絞り込みもボタンにして
  /// この行に入れる。縦は下の [SelectedTagBar] の行）
  Widget _buildSearchRow({bool inline = false, List<Tag> tags = const []}) {
    return Padding(
          padding: inline
              ? EdgeInsets.zero
              : const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: GlassSearchField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: (v) {
                    setState(() => _searchQuery = v);
                  },
                  onClear: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
              ),
              if (inline && tags.isNotEmpty) ...[
                const SizedBox(width: AppSpacing.md),
                TagFilterButton(
                    tags: tags, onClosed: _searchFocusNode.unfocus),
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
        );
  }

  /// 見出しの右側: 表示の切り替え（タブごと）・設定。
  /// 複数選択のボタンは置かない（長押しで入れる。v1.143.0 で外した）
  List<Widget> _buildAppBarActions() {
    final Widget viewButton = switch (_tab) {
      _tabTags => PopupMenuButton<TagViewMode>(
          icon: Icon(_tagViewMode.icon),
          tooltip: '表示の切り替え',
          initialValue: _tagViewMode,
          onSelected: _setTagViewMode,
          itemBuilder: (_) => [
            for (final m in TagViewMode.values)
              CheckedPopupMenuItem(
                value: m,
                checked: m == _tagViewMode,
                child: Text(m.label),
              ),
          ],
        ),
      _tabItems => PopupMenuButton<ItemViewMode>(
          icon: Icon(_itemViewMode.icon),
          tooltip: '表示の切り替え',
          initialValue: _itemViewMode,
          onSelected: _setItemViewMode,
          itemBuilder: (_) => [
            for (final m in ItemViewMode.values)
              CheckedPopupMenuItem(
                value: m,
                checked: m == _itemViewMode,
                child: Text(m.label),
              ),
          ],
        ),
      _ => IconButton(
          icon: Icon(_playlistGrid ? Icons.grid_view : Icons.view_list),
          onPressed: _togglePlaylistGrid,
          tooltip: _playlistGrid ? 'リスト表示へ' : 'グリッド表示へ',
        ),
    };
    return [
      viewButton,
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
  /// タブ（セグメント 36 + 上下の余白）と選択バーの高さ。切り替えても一覧が動かないように
  static const _topBarHeight = 44.0;

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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSizes.md),
            tooltip: '選択をやめる',
            visualDensity: VisualDensity.compact,
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
        padding: const EdgeInsets.symmetric(horizontal: 6),
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
