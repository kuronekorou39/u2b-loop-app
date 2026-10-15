import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_sheets.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../core/utils/id_generator.dart';
import '../../models/playlist.dart';
import '../../providers/data_provider.dart';

/// 複数選択した曲をプレイリストに足すシート（曲の詳細の「プレイリストに追加」と同じ見た目）。
/// 先頭は「新しいプレイリストを作って追加」。足したら [onAdded]
Future<void> showAddItemsToPlaylistSheet(
  BuildContext context,
  WidgetRef ref, {
  required List<String> itemIds,
  VoidCallback? onAdded,
}) {
  final playlists = ref.read(playlistsProvider);
  final allItems = ref.read(loopItemsProvider);

  Future<void> addTo(Playlist pl) async {
    await ref.read(playlistsProvider.notifier).addItems(pl.id, itemIds);
    onAdded?.call();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success('${itemIds.length}件を「${pl.name}」に追加しました'),
      );
    }
  }

  Future<void> addToNew() async {
    final name = await AppDialogs.prompt(context,
        title: '新しいプレイリスト',
        hintText: 'プレイリスト名',
        confirmLabel: '作成',
        maxLength: AppLimits.playlistNameMaxLength);
    if (name == null) return;
    final pl = Playlist(id: IdGenerator.next(), name: name);
    await ref.read(playlistsProvider.notifier).add(pl);
    await addTo(pl);
  }

  return AppSheets.actions(
    context,
    title: 'プレイリストに追加（${itemIds.length}件）',
    note: playlists.isEmpty ? 'プレイリストがありません' : null,
    actions: [
      SheetAction(
        icon: Icons.playlist_add,
        label: '新しいプレイリストを作って追加',
        onTap: addToNew,
      ),
      for (final pl in playlists)
        SheetAction(
          icon: Icons.playlist_play,
          label: pl.name,
          subtitle:
              '${pl.itemIds.where((id) => allItems.any((i) => i.id == id)).length} 曲',
          onTap: () => addTo(pl),
        ),
    ],
  );
}
