import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_sheets.dart';
import '../../core/utils/id_generator.dart';
import '../../models/loop_item.dart';
import '../../models/playlist.dart';
import '../../providers/data_provider.dart';
import '../../widgets/empty_hint.dart';
import '../../widgets/glass_controls.dart';
import '../../widgets/item_thumbnail.dart';
import '../player_screen.dart';
import '../playlist_detail_screen.dart';
import 'home_parts.dart';

/// ホームの「プレイリスト」タブ。一覧・再生・複製・削除。
class PlaylistTab extends ConsumerWidget {
  const PlaylistTab({super.key});

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final items = ref.watch(loopItemsProvider);
    final textTheme = Theme.of(context).textTheme;

    if (playlists.isEmpty) {
      return const EmptyHint(
          icon: Icons.playlist_play,
          title: 'プレイリストがありません',
          subtitle: '＋ ボタンで新規作成');
    }

    return HomeListSurface(
      child: ListView.builder(
        padding: HomeListSurface.listPadding,
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          final pl = playlists[i];
          final count =
              pl.itemIds.where((id) => items.any((item) => item.id == id)).length;
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
                // heroTag は付けない（アイテムカードと重複してクラッシュする）
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
            subtitle: Text('$count 曲', style: textTheme.bodySmall),
            trailing: Row(
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
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => PlaylistDetailScreen(playlistId: pl.id)),
            ),
            onLongPress: () => _showMenu(context, ref, pl),
          );
        },
      ),
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
          onTap: () => ref.read(playlistsProvider.notifier).duplicate(pl.id),
        ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () async {
            final ok = await AppDialogs.confirmDelete(context,
                message: '「${pl.name}」を削除しますか？');
            if (ok) ref.read(playlistsProvider.notifier).delete(pl.id);
          },
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
