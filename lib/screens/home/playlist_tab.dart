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
import '../../providers/data_provider.dart';
import '../../widgets/selection_mark.dart';
import '../../widgets/empty_hint.dart';
import '../../widgets/glass_controls.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/item_thumbnail.dart';
import '../player_screen.dart';
import '../playlist_detail_screen.dart';
import 'home_parts.dart';

/// ホームの「プレイリスト」タブ。一覧（リスト / カードのグリッド）・再生・複製・削除。
/// 複数選択中（[selecting]）はタップで選択の切替、操作はホームの選択バー側
class PlaylistTab extends ConsumerWidget {
  const PlaylistTab({
    super.key,
    this.grid = false,
    this.selecting = false,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onLongPress,
  });

  final bool grid;
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<Playlist>? onToggleSelect;
  final ValueChanged<Playlist>? onLongPress;

  /// FAB の「プレイリストを作成」
  static Future<void> createPlaylist(BuildContext context, WidgetRef ref) async {
    final name = await AppDialogs.prompt(context,
        title: 'プレイリスト作成',
        hintText: 'プレイリスト名',
        confirmLabel: '作成',
        maxLength: AppLimits.playlistNameMaxLength);
    if (name == null) return;
    await ref
        .read(playlistsProvider.notifier)
        .add(Playlist(id: IdGenerator.next(), name: name));
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
      ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar.success('${playlists.length} 件を複製しました'));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final items = ref.watch(loopItemsProvider);

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

    void tap(Playlist pl) {
      if (selecting) {
        onToggleSelect?.call(pl);
      } else {
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(playlistId: pl.id)));
      }
    }

    if (grid) {
      return _buildGrid(context, ref, playlists, items, countOf, thumbOf, tap);
    }

    final textTheme = Theme.of(context).textTheme;
    return HomeListSurface(
      child: ListView.builder(
        padding: HomeListSurface.listPadding,
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          final pl = playlists[i];
          final count = countOf(pl);
          final selected = selectedIds.contains(pl.id);
          return ListTile(
            selected: selected,
            leading: ClipRRect(
              borderRadius: AppRadius.borderMd,
              child: SizedBox(
                width: 56,
                height: 56,
                child: _Thumb(item: thumbOf(pl)),
              ),
            ),
            title: Text(pl.name),
            subtitle: Text('$count 曲', style: textTheme.bodySmall),
            // 選択の印は右端の再生・メニューの場所に（隠すだけで場所は残す）
            trailing: SelectionTrailing(
                selecting: selecting,
                selected: selected,
                child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (count > 0)
                        GreenButton(
                          icon: Icons.play_arrow_rounded,
                          label: '再生',
                          size: 34,
                          onPressed: () => _play(context, pl, items),
                        ),
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: AppIconSizes.md),
                        tooltip: 'メニュー',
                        onPressed: () => _showMenu(context, ref, pl),
                      ),
                    ],
                  ),
            ),
            onTap: () => tap(pl),
            onLongPress: () => onLongPress?.call(pl),
          );
        },
      ),
    );
  }

  /// グリッド: サムネ（16:9）+ 名前 + 曲数のカード。再生はサムネ右下のボタン
  Widget _buildGrid(
    BuildContext context,
    WidgetRef ref,
    List<Playlist> playlists,
    List<LoopItem> items,
    int Function(Playlist) countOf,
    LoopItem? Function(Playlist) thumbOf,
    void Function(Playlist) tap,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 80 + bottomPad),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 16 / 14,
        crossAxisSpacing: AppSpacing.md + 2,
        mainAxisSpacing: AppSpacing.md + 2,
      ),
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final pl = playlists[i];
        final count = countOf(pl);
        final selected = selectedIds.contains(pl.id);
        return GlassSurface(
          radius: 16,
          padding: const EdgeInsets.all(AppSpacing.md),
          tint: selected ? AppTheme.accentGreen.withValues(alpha: 0.15) : null,
          onTap: () => tap(pl),
          onLongPress: () => onLongPress?.call(pl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _Thumb(item: thumbOf(pl)),
                      if (!selecting && count > 0)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: GreenButton(
                            icon: Icons.play_arrow_rounded,
                            size: 32,
                            tooltip: '再生',
                            onPressed: () => _play(context, pl, items),
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
                              border:
                                  Border.all(color: Colors.white70, width: 2),
                            ),
                            width: 20,
                            height: 20,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(pl.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text('$count 曲', style: textTheme.labelSmall),
            ],
          ),
        );
      },
    );
  }

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
