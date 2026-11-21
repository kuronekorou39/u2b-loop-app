import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_sheets.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../core/utils/id_generator.dart';
import '../../models/loop_item.dart';
import '../../models/playlist.dart';
import '../../models/tag.dart';
import '../../providers/data_provider.dart';
import '../../widgets/drag_reorder_grid.dart';
import '../../widgets/now_playing_mark.dart';
import '../../widgets/playlist_cover.dart';
import '../../widgets/reorder_handle.dart';
import '../../widgets/selection_mark.dart';
import '../../widgets/empty_hint.dart';
import '../../widgets/glass_controls.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/item_thumbnail.dart';
import '../../widgets/tag_chip.dart';
import '../player_screen.dart';
import '../playlist_detail_screen.dart';
import '../playlist_item_picker_screen.dart';
import 'home_parts.dart';

/// ホームの「プレイリスト」タブ。一覧（リスト / カードのグリッド）・再生・複製・削除。
/// 複数選択中（[selecting]）はタップで選択の切替、操作はホームの選択バー側。
/// 並べ替えモード（[reordering]。ホームの見出しのボタンでオンオフ）の間は、リストは
/// 再生・⋮ の場所が ≡ になり、グリッドはカードを長押しして動かす（開かない・選択しない）
class PlaylistTab extends ConsumerWidget {
  const PlaylistTab({
    super.key,
    this.grid = false,
    this.selecting = false,
    this.selectedIds = const {},
    this.reordering = false,
    this.onToggleSelect,
    this.onLongPress,
  });

  final bool grid;
  final bool selecting;
  final Set<String> selectedIds;
  final bool reordering;
  final ValueChanged<Playlist>? onToggleSelect;
  final ValueChanged<Playlist>? onLongPress;

  /// 並べ替えモードで ≡ を置く列の幅（触れてすぐ動かせる範囲。行の右端まで）
  static const double _handleColumnWidth = 72;

  /// 空で作ったときの名前（名前は後から変えられるので、作るときには聞かない）
  static const newPlaylistName = '新しいプレイリスト';

  /// FAB の「プレイリストを作成」。空で作るか、タグから作るかを選ぶ
  static Future<void> createPlaylist(BuildContext context, WidgetRef ref) async {
    final fromTags = await _showCreateDialog(context);
    if (fromTags == null || !context.mounted) return;
    final notifier = ref.read(playlistsProvider.notifier);
    if (!fromTags) {
      await notifier.add(Playlist(id: IdGenerator.next(), name: newPlaylistName));
      return;
    }
    final tags = ref.read(tagsProvider);
    if (tags.isEmpty) {
      AppToast.instance.show(AppSnackBar.info('タグがありません'));
      return;
    }
    final allItems = ref.read(loopItemsProvider);
    final result = await showPlaylistTagsDialog(context,
        tags: tags,
        selected: const {},
        countOf: (tag) => allItems
            .where((i) => i.isReady && i.tagIds.contains(tag.id))
            .length,
        thumbOf: (tag) => tag.thumbItemOf(allItems));
    if (result == null || result.isEmpty) return;
    // 名前は選んだタグの名前から（タグ一覧の並び）
    final name = AppLimits.clip(
        [
          for (final t in tags)
            if (result.contains(t.id)) t.name
        ].join('・'),
        AppLimits.playlistNameMaxLength);
    final id = IdGenerator.next();
    await notifier.add(Playlist(id: id, name: name));
    await notifier.setTags(id, result);
  }

  /// 作り方を選ぶ。false = 空で作る、true = タグから作る、null = やめた
  static Future<bool?> _showCreateDialog(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('プレイリストを作成', style: textTheme.displaySmall),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.playlist_add, color: AppTheme.accentGreen),
                title: Text('空で作る', style: textTheme.bodyLarge),
                onTap: () => Navigator.pop(ctx, false),
              ),
              ListTile(
                leading:
                    const Icon(Icons.label_outline, color: AppTheme.accentGreen),
                title: Text('タグから作る', style: textTheme.bodyLarge),
                onTap: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// まとめて削除（確認つき）。戻り値は消したか
  static Future<bool> deletePlaylists(
      BuildContext context, WidgetRef ref, List<Playlist> playlists) async {
    if (playlists.isEmpty) return false;
    final name = playlists.length == 1
        ? '「${playlists.first.name}」'
        : 'プレイリスト ${playlists.length} 件';
    final ok = await AppDialogs.confirmDelete(context,
        message: '$nameを削除しますか？（曲は残ります）');
    if (!ok) return false;
    for (final pl in playlists) {
      await ref.read(playlistsProvider.notifier).delete(pl.id);
    }
    return true;
  }

  static Future<void> duplicatePlaylists(
      BuildContext context, WidgetRef ref, List<Playlist> playlists) async {
    for (final pl in playlists) {
      await ref.read(playlistsProvider.notifier).duplicate(pl.id);
    }
    if (context.mounted && playlists.length > 1) {
      AppToast.instance.show(
          AppSnackBar.success('${playlists.length} 件を複製しました'));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final items = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);

    if (playlists.isEmpty) {
      return const EmptyHint(
          icon: Icons.playlist_play,
          title: 'プレイリストがありません',
          subtitle: '＋ ボタンで新規作成');
    }

    int countOf(Playlist pl) =>
        pl.itemIds.where((id) => items.any((item) => item.id == id)).length;
    LoopItem? thumbOf(Playlist pl) {
      final id = pl.effectiveThumbnailItemId;
      return id == null ? null : items.where((item) => item.id == id).firstOrNull;
    }

    // 自動で入れるタグ（タグ一覧の並び）
    List<Tag> tagsOf(Playlist pl) => pl.tagIds.isEmpty
        ? const []
        : [
            for (final t in tags)
              if (pl.tagIds.contains(t.id)) t
          ];

    final reorder = ref.read(playlistsProvider.notifier).reorder;
    void tap(Playlist pl) {
      if (reordering) return;
      if (selecting) {
        onToggleSelect?.call(pl);
      } else {
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(playlistId: pl.id)));
      }
    }

    if (grid) {
      return _buildGrid(
          context, ref, playlists, items, countOf, thumbOf, tagsOf, tap, reorder);
    }

    final textTheme = Theme.of(context).textTheme;
    return HomeListSurface(
      child: ReorderableListView.builder(
        padding: HomeListSurface.listPadding,
        buildDefaultDragHandles: false,
        itemCount: playlists.length,
        onReorderItem: reorder,
        itemBuilder: (context, i) {
          final pl = playlists[i];
          final count = countOf(pl);
          final autoTags = tagsOf(pl);
          final selected = selectedIds.contains(pl.id);
          return SelectionDim(
            key: ValueKey(pl.id),
            selecting: selecting,
            selected: selected,
            // 並べ替えモードは行に触れるとほぼすぐ持ち上がる（ふだんの長押しは選択）
            child: Stack(children: [
            ReorderRowListener(
            index: i,
            enabled: reordering,
            child: ListTile(
            selected: selected,
            // タグの無い行（1 行）も同じ高さに（表紙が上下の行とくっつかないように）
            minTileHeight: _listRowMinHeight,
            // 曲の束に見せる表紙（板 2 枚 + 左下に曲数の札）。高さは今までの 56 に収める
            leading: SizedBox(
              width: _listCoverSize,
              child: PlaylistCover(
                image: _Thumb(item: thumbOf(pl)),
                count: count,
                compact: true,
                radius: AppRadius.md,
                aspectRatio: _listCoverSize /
                    (_listCoverSize - PlaylistCover.stackHeightOf(compact: true)),
                overlays: [NowPlayingMark(playlistId: pl.id, size: 18)],
              ),
            ),
            title: Text(pl.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            // 曲数は表紙の札。下には自動で入れるタグ（2 つ目からは +N）
            subtitle: autoTags.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: TagChip(tag: autoTags.first)),
                        if (autoTags.length > 1)
                          Text(' +${autoTags.length - 1}',
                              style: textTheme.labelSmall),
                      ],
                    ),
                  ),
            // 選択の印は右端の再生・メニューの場所に（隠すだけで場所は残す）
            trailing: SelectionTrailing(
                selecting: selecting,
                selected: selected,
                // 並べ替えモードは ⋮ とまったく同じ場所が ≡。再生は隠すだけで場所は残す
                // （名前の折り返しが変わらないように）。ボタンの上の長押しも行の選択に
                child: ItemInnerButtons(child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (count > 0)
                        Visibility(
                          visible: !reordering,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: GreenButton(
                            icon: Icons.play_arrow_rounded,
                            label: '再生',
                            size: 34,
                            onPressed: () => _play(context, pl, items),
                          ),
                        ),
                      if (reordering)
                        const SizedBox(
                          width: kMinInteractiveDimension,
                          height: kMinInteractiveDimension,
                          child: Center(child: ReorderHandleIcon()),
                        )
                      else
                        IconButton(
                          icon:
                              const Icon(Icons.more_vert, size: AppIconSizes.md),
                          tooltip: 'メニュー',
                          onPressed: () => _showMenu(context, ref, pl),
                        ),
                    ],
                  )),
            ),
            onTap: reordering ? null : () => tap(pl),
            onLongPress: reordering ? null : () => onLongPress?.call(pl),
          )),
            // ≡ の列（行の右端まで、行の高さいっぱい）は触れてすぐ動かせる
            if (reordering)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: _handleColumnWidth,
                child: ReorderHandle.area(index: i),
              ),
          ]),
          );
        },
      ),
    );
  }

  /// グリッド: 正方形のジャケット（曲の束に見せる板と曲数の札）+ 名前 + 自動で入れるタグのカード。
  /// 曲のグリッド（横長のサムネ）と形で見分けられるように。再生は表紙の右下のボタン。
  /// 表紙が正方形なのでカードの高さは幅で決まる（列の幅から求める）
  Widget _buildGrid(
    BuildContext context,
    WidgetRef ref,
    List<Playlist> playlists,
    List<LoopItem> items,
    int Function(Playlist) countOf,
    LoopItem? Function(Playlist) thumbOf,
    List<Tag> Function(Playlist) tagsOf,
    void Function(Playlist) tap,
    void Function(int, int) reorder,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth - AppSpacing.lg * 2;
      // SliverGridDelegateWithMaxCrossAxisExtent と同じ列数の決め方
      final columns = max(1, (width / (_gridMaxCardWidth + _gridSpacing)).ceil());
      final cardWidth = (width - _gridSpacing * (columns - 1)) / columns;
      final cardHeight = cardWidth +
          PlaylistCover.stackHeightOf(compact: false) +
          AppSpacing.sm +
          _gridNameHeight +
          _gridInfoHeight;
      return DragReorderGrid<Playlist>(
        items: playlists,
        idOf: (pl) => pl.id,
        reordering: reordering,
        onReorder: reorder,
        padding: EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 80 + bottomPad),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: cardHeight,
          crossAxisSpacing: _gridSpacing,
          mainAxisSpacing: _gridSpacing,
        ),
        itemBuilder: (context, pl) {
          final count = countOf(pl);
          final autoTags = tagsOf(pl);
          final selected = selectedIds.contains(pl.id);
          return SelectionDim(
            selecting: selecting,
            selected: selected,
            child: GlassSurface(
              radius: 16,
              padding: const EdgeInsets.all(AppSpacing.md),
              tint: selected ? AppTheme.accentGreen.withValues(alpha: 0.15) : null,
              onTap: reordering ? null : () => tap(pl),
              onLongPress: reordering ? null : () => onLongPress?.call(pl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PlaylistCover(
                    image: _Thumb(item: thumbOf(pl)),
                    count: count,
                    overlays: [
                      NowPlayingMark(playlistId: pl.id, size: 20),
                      if (!selecting && !reordering && count > 0)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          // 再生ボタンの上の長押しもカードの選択に
                          child: ItemInnerButtons(
                            child: GreenButton(
                              icon: Icons.play_arrow_rounded,
                              size: 32,
                              tooltip: '再生',
                              onPressed: () => _play(context, pl, items),
                            ),
                          ),
                        ),
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
                                size: AppIconSizes.xs,
                                color: AppTheme.darkBackground),
                          ),
                        ),
                      if (selecting && !selected)
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
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    height: _gridNameHeight,
                    child: Text(pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  // 自動で入れるタグ（入りきらない分は +N）。曲数は表紙の札
                  SizedBox(
                    height: _gridInfoHeight,
                    child: Row(
                      children: [
                        if (autoTags.isNotEmpty) ...[
                          Flexible(
                              child: TagChip(tag: autoTags.first, small: true)),
                          if (autoTags.length > 1)
                            Text(' +${autoTags.length - 1}',
                                style: textTheme.labelSmall),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    });
  }

  /// リストの行の表紙の大きさ（板の分も含めて今までのサムネと同じ 56）
  static const double _listCoverSize = 56;

  /// リストの行の高さの下限（表紙の上下に少し空ける）
  static const double _listRowMinHeight = 72;

  /// グリッドのカードの幅の上限（これを超えない列数にする）と間
  static const double _gridMaxCardWidth = 220;
  static const double _gridSpacing = AppSpacing.md + 2;

  /// グリッドの名前の行の高さ
  static const double _gridNameHeight = 20;

  /// グリッドのタグの行の高さ（タグのチップがあっても無くても同じ）
  static const double _gridInfoHeight = 18;

  void _showMenu(BuildContext context, WidgetRef ref, Playlist pl) {
    AppSheets.actions(
      context,
      title: pl.name,
      actions: [
        SheetAction(
          icon: Icons.copy_outlined,
          label: '複製',
          onTap: () => duplicatePlaylists(context, ref, [pl]),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => deletePlaylists(context, ref, [pl]),
        ),
      ],
    );
  }

  void _play(BuildContext context, Playlist pl, List<LoopItem> allItems) {
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
}

/// プレイリストのサムネ（先頭曲など）。無ければ薄い面にアイコン。
/// heroTag は付けない（アイテムカードと重複してクラッシュする）
class _Thumb extends StatelessWidget {
  const _Thumb({required this.item});

  final LoopItem? item;

  @override
  Widget build(BuildContext context) {
    if (item != null) return ItemThumbnail(item: item!);
    return Container(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      child: Icon(Icons.playlist_play, color: AppTheme.muted(context)),
    );
  }
}
