
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/audio/track_compatibility.dart';
import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import '../providers/player_provider.dart';
import '../services/audio_analysis_service.dart';
import '../services/share_service.dart';
import '../providers/thumb_tone_provider.dart';
import '../widgets/empty_hint.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/glass_surface.dart';
import '../widgets/item_thumbnail.dart';
import '../widgets/tag_chip.dart';
import 'detail_screen.dart';
import 'player_screen.dart';
import 'playlist_item_picker_screen.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';

enum _PlaylistMenu { analyze, sortByCompatibility }

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  void _renamePlaylist(Playlist pl) async {
    final newName = await AppDialogs.prompt(context,
        title: 'プレイリスト名変更',
        initialValue: pl.name,
        confirmLabel: '変更',
        maxLength: AppLimits.playlistNameMaxLength);
    if (newName != null && newName != pl.name) {
      pl.name = newName;
      ref.read(playlistsProvider.notifier).update(pl);
    }
  }

  Future<void> _deletePlaylist(Playlist pl) async {
    final confirmed = await AppDialogs.confirmDelete(context,
        message: '「${pl.name}」を削除しますか？');
    if (confirmed && mounted) {
      ref.read(playlistsProvider.notifier).delete(pl.id);
      Navigator.of(context).pop();
    }
  }

  void _toast(SnackBar bar) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(bar);
  }

  /// 未解析の曲を1曲ずつ順に解析する。音声の取得に時間がかかるので
  /// 進捗ダイアログを出し、途中で止められるようにする
  Future<void> _analyzeUnanalyzed(List<LoopItem> items) async {
    final targets = AudioAnalysisService.unanalyzed(items);
    if (targets.isEmpty) {
      _toast(AppSnackBar.info('すべて解析済みです'));
      return;
    }
    final progress = ValueNotifier<(int done, String title)>((0, targets.first.title));
    final cancelled = ValueNotifier<bool>(false);
    BuildContext? dialogContext;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        final textTheme = Theme.of(ctx).textTheme;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('テンポ/キーを解析中'),
            content: ValueListenableBuilder<(int, String)>(
              valueListenable: progress,
              builder: (_, p, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: p.$1 / targets.length),
                  const SizedBox(height: AppSpacing.sm),
                  Text('${p.$1} / ${targets.length}', style: textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(p.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall),
                ],
              ),
            ),
            actions: [
              ValueListenableBuilder<bool>(
                valueListenable: cancelled,
                builder: (_, c, _) => TextButton(
                  onPressed: c ? null : () => cancelled.value = true,
                  child: Text(c ? 'この曲で止めます…' : '中止'),
                ),
              ),
            ],
          ),
        );
      },
    );

    final (:done, :skipped) = await AudioAnalysisService.analyzeAll(
      ref.read(loopItemsProvider.notifier),
      ref.read(youtubeServiceProvider),
      targets,
      onProgress: (i, _, current) => progress.value = (i, current.title),
      shouldStop: () => cancelled.value,
    );
    final wasCancelled = cancelled.value;
    progress.dispose();
    cancelled.dispose();
    if (dialogContext != null && dialogContext!.mounted) {
      Navigator.of(dialogContext!).pop();
    }
    if (!mounted) return;
    final failed = targets.length - done - skipped;
    final notes = <String>[
      if (wasCancelled) '中止',
      if (skipped > 0)
        '$skipped 曲は ${AudioAnalysisService.maxAnalyzableMinutes} 分以上なので省略',
      if (!wasCancelled && failed > 0) '$failed 曲は取得できず',
    ];
    _toast(AppSnackBar.success(
      '$done 曲を解析しました${notes.isEmpty ? '' : '（${notes.join('、')}）'}',
    ));
  }

  /// テンポ/キーの相性が良い曲が続くように並べ替えて保存する
  void _sortByCompatibility(Playlist pl, List<LoopItem> items) {
    final unknown = items.where((i) => !TrackCompatibility.isAnalyzed(i)).length;
    if (items.length - unknown < 2) {
      _toast(AppSnackBar.info('解析済みの曲が2曲以上必要です'));
      return;
    }
    final ids = TrackCompatibility.order(items).map((e) => e.id).toList();
    // items は孤児IDを除いた表示用リストなので、残りは末尾に温存する
    final orphans = pl.itemIds.where((id) => !ids.contains(id)).toList();
    pl.itemIds = [...ids, ...orphans];
    ref.read(playlistsProvider.notifier).update(pl);
    _toast(AppSnackBar.success(
        '相性順に並べ替えました${unknown > 0 ? '（未解析の $unknown 曲は末尾）' : ''}'));
  }

  void _sharePlaylist(Playlist pl, List<LoopItem> items) {
    final tags = ref.read(tagsProvider);
    final tagIdToName = {for (final t in tags) t.id: t.name};
    final youtubeItems =
        items.where((i) => i.videoId != null && i.videoId!.isNotEmpty).toList();

    if (youtubeItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.info('YouTube動画がありません'),
      );
      return;
    }

    final url = ShareService.encode(
      playlistName: pl.name,
      items: youtubeItems,
      tagIdToName: tagIdToName,
    );

    const maxShareLength = 9500;
    if (url.length > maxShareLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.error(
            '共有データが大きすぎます（${youtubeItems.length}曲/${url.length}文字）。目安150曲以下に減らしてください。'),
      );
      return;
    }

    final canQr = url.length <= AppLimits.qrMaxLength;

    AppSheets.actions(
      context,
      title: '「${pl.name}」を共有',
      subtitle: '${youtubeItems.length} 曲（${url.length} 文字）',
      note: canQr ? null : '曲数が多いため QR コードは使えません',
      actions: [
        SheetAction(
          icon: Icons.share_outlined,
          label: 'テキストで共有',
          subtitle: 'LINE、メールなどで送信',
          onTap: () => Share.share(url),
        ),
        SheetAction(
          icon: Icons.content_copy,
          label: 'URL をコピー',
          onTap: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context).showSnackBar(
              AppSnackBar.success('URL をコピーしました'),
            );
          },
        ),
        if (canQr)
          SheetAction(
            icon: Icons.qr_code,
            label: 'QR コードを表示',
            onTap: () => _showQrDialog(pl.name, url),
          ),
      ],
    );
  }

  void _showQrDialog(String name, String url) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name, style: Theme.of(context).textTheme.titleMedium),
        content: SizedBox(
          width: 250,
          height: 250,
          child: Center(
            child: QrImageView(
              data: url,
              size: 240,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  void _selectThumbnail(Playlist pl, List<LoopItem> items) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('サムネイル選択',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            if (pl.thumbnailItemId != null)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('デフォルトに戻す（1曲目）'),
                onTap: () {
                  ref
                      .read(playlistsProvider.notifier)
                      .setThumbnailItem(pl.id, null);
                  Navigator.pop(ctx);
                },
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final item = items[i];
                  final isCurrent =
                      item.id == pl.effectiveThumbnailItemId;
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: AppRadius.borderXs,
                      child: SizedBox(
                        width: 48,
                        height: 36,
                        child: ItemThumbnail(item: item, iconSize: AppIconSizes.sm),
                      ),
                    ),
                    title: Text(item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium),
                    trailing: isCurrent
                        ? const Icon(Icons.check,
                            color: Colors.green, size: AppIconSizes.md)
                        : null,
                    onTap: () {
                      ref
                          .read(playlistsProvider.notifier)
                          .setThumbnailItem(pl.id, item.id);
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// スワイプで外したあと「元に戻す」で同じ位置に戻せる
  void _removeItem(Playlist pl, String itemId) {
    final itemIds = List<String>.from(pl.itemIds);
    final regions = pl.regionSelections[itemId];
    final title = ref
            .read(loopItemsProvider)
            .where((i) => i.id == itemId)
            .firstOrNull
            ?.title ??
        '曲';
    ref.read(playlistsProvider.notifier).removeItem(pl.id, itemId);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(AppSnackBar.action(
        '「$title」をプレイリストから外しました',
        label: '元に戻す',
        onPressed: () {
          final current = ref
              .read(playlistsProvider)
              .where((p) => p.id == pl.id)
              .firstOrNull;
          if (current == null) return;
          current.itemIds = itemIds;
          // 戻した曲は手で足した曲として残す（タグで自動に外した印は消す）
          current.excludedItemIds.remove(itemId);
          if (regions != null) current.regionSelections[itemId] = regions;
          ref.read(playlistsProvider.notifier).update(current);
        },
      ));
  }

  /// 行の ⋮ と長押しから。スワイプでしかできなかった「外す」と、
  /// サムネのタップでしかできなかった有効・無効もここに置く
  void _showItemMenu(Playlist pl, LoopItem item, int index) {
    final disabled = pl.disabledItemIds.contains(item.id);
    AppSheets.actions(
      context,
      title: item.title,
      actions: [
        if (index > 0)
          SheetAction(
            icon: Icons.vertical_align_top,
            label: '先頭に移動',
            onTap: () {
              // 表示の index は孤児を除いた並びなので ID で動かす
              pl.itemIds.remove(item.id);
              pl.itemIds.insert(0, item.id);
              ref.read(playlistsProvider.notifier).update(pl);
            },
          ),
        if (_hasItemRegions(item))
          SheetAction(
            icon: Icons.tune,
            label: '区間を選択',
            onTap: () => _showRegionEditSheet(pl, item),
          ),
        SheetAction(
          icon: disabled ? Icons.play_circle_outline : Icons.block,
          label: disabled ? '再生に含める' : '再生から外す（スキップ）',
          subtitle: disabled ? null : 'プレイリストには残したまま飛ばします',
          onTap: () {
            ref
                .read(playlistsProvider.notifier)
                .toggleItemEnabled(pl.id, item.id);
            ScaffoldMessenger.of(context).showSnackBar(AppSnackBar.success(
                disabled ? '「${item.title}」を再生に含めます' : '「${item.title}」をスキップします'));
          },
        ),
        SheetAction(
          icon: Icons.playlist_remove,
          label: 'プレイリストから外す',
          destructive: true,
          onTap: () async {
            final ok = await AppDialogs.confirmDelete(context,
                message: '「${item.title}」をプレイリストから削除しますか？');
            if (ok && mounted) _removeItem(pl, item.id);
          },
        ),
      ],
    );
  }

  // --- アイテム追加 ---

  /// 入口は他の「追加」と同じく中央のダイアログ（以前は下からのシートだった）
  Future<void> _showAddDialog(Playlist pl) async {
    final choice = await showPlaylistAddDialog(context);
    if (!mounted || choice == null) return;
    switch (choice) {
      case PlaylistAddChoice.pick:
        _showItemPicker(pl);
      case PlaylistAddChoice.byTag:
        await _showTagPicker(pl);
    }
  }

  void _showItemPicker(Playlist pl) {
    final readyItems =
        ref.read(loopItemsProvider).where((i) => i.isReady).toList();
    final tags = ref.read(tagsProvider);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistItemPickerScreen(
          items: readyItems,
          tags: tags,
          existingIds: Set<String>.from(pl.itemIds),
          onAdd: (ids, regions) {
            ref
                .read(playlistsProvider.notifier)
                .addItems(pl.id, ids, regions: regions);
            ScaffoldMessenger.of(context).showSnackBar(
              AppSnackBar.success('${ids.length}件を追加しました'),
            );
          },
        ),
      ),
    );
  }

  /// 自動で入れるタグを選ぶ（どれか 1 つが付いた曲が入る。後からタグを付けた曲も入る）
  Future<void> _showTagPicker(Playlist pl) async {
    final tags = ref.read(tagsProvider);
    final allItems = ref.read(loopItemsProvider);
    int countOf(Tag tag) =>
        allItems.where((i) => i.isReady && i.tagIds.contains(tag.id)).length;

    final result = await showPlaylistTagsDialog(context,
        tags: tags,
        selected: pl.tagIds.toSet(),
        countOf: countOf,
        excludedCount: pl.excludedItemIds.length);
    if (result == null || !mounted) return;
    final notifier = ref.read(playlistsProvider.notifier);
    final before = pl.itemIds.length;
    await notifier.setTags(pl.id, result.tagIds);
    if (result.restoreExcluded) await notifier.restoreExcluded(pl.id);
    if (!mounted) return;
    final after = ref
            .read(playlistsProvider)
            .where((p) => p.id == pl.id)
            .firstOrNull
            ?.itemIds
            .length ??
        before;
    final added = after - before;
    ScaffoldMessenger.of(context).showSnackBar(AppSnackBar.success(
        result.tagIds.isEmpty
            ? 'タグでの自動追加をやめました'
            : added > 0
                ? '$added 曲が入りました'
                : 'タグを設定しました'));
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final pl =
        playlists.where((p) => p.id == widget.playlistId).firstOrNull;
    final allItems = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);

    if (pl == null) {
      return const GlassScaffold(
        title: Text('プレイリスト'),
        body: Center(child: Text('プレイリストが見つかりません')),
      );
    }

    // プレイリスト内のアイテムを取得（順序維持）
    final items = <LoopItem>[];
    for (final id in pl.itemIds) {
      final item = allItems.where((i) => i.id == id).firstOrNull;
      if (item != null) items.add(item);
    }

    final thumbItemId = pl.effectiveThumbnailItemId;
    final thumbItem = thumbItemId != null
        ? allItems.where((i) => i.id == thumbItemId).firstOrNull
        : null;

    final textTheme = Theme.of(context).textTheme;
    final thumbPath = thumbItem?.thumbnailPath;
    final tone = thumbPath == null
        ? null
        : ref.watch(thumbToneProvider(thumbPath)).valueOrNull;

    return GlassScaffold(
      // ガラス風: 背景（サムネの色味）を AppBar の裏まで通す
      tone: tone,
      title: Text('プレイリスト', style: textTheme.titleMedium),
      actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: '共有',
              onPressed: () => _sharePlaylist(pl, items),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: '削除',
            onPressed: () => _deletePlaylist(pl),
          ),
          if (items.isNotEmpty)
            PopupMenuButton<_PlaylistMenu>(
              tooltip: 'その他',
              onSelected: (m) => switch (m) {
                _PlaylistMenu.analyze => _analyzeUnanalyzed(items),
                _PlaylistMenu.sortByCompatibility =>
                  _sortByCompatibility(pl, items),
              },
              itemBuilder: (_) {
                final unanalyzed = AudioAnalysisService.unanalyzed(items).length;
                return [
                  PopupMenuItem(
                    value: _PlaylistMenu.analyze,
                    enabled: unanalyzed > 0,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.music_note),
                      title: const Text('テンポ/キーをまとめて解析'),
                      subtitle: Text(unanalyzed > 0
                          ? '未解析・要更新 $unanalyzed 曲を順に解析'
                          : 'すべて解析済み'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: _PlaylistMenu.sortByCompatibility,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.join_inner),
                      title: Text('相性順に並べ替え'),
                      subtitle: Text('テンポとキーが近い曲が続くように'),
                    ),
                  ),
                ];
              },
            ),
        ],
      // 本文の上端は bodyBuilder の context から（AppBar の高さが入る）
      bodyBuilder: (bodyContext) => SafeArea(
        top: false,
        bottom: false,
        child: Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(bodyContext).top + AppSpacing.xs),
          // ヘッダー
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // サムネイル + 編集ボタン
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        width: 120,
                        height: 90,
                        child: thumbItem != null
                            ? ItemThumbnail(item: thumbItem, iconSize: AppIconSizes.sm)
                            : Container(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.08),
                                child: Icon(Icons.playlist_play,
                                    color: AppTheme.muted(context), size: 40),
                              ),
                      ),
                    ),
                    if (items.isNotEmpty)
                      Positioned(
                        right: 2,
                        top: 2,
                        child: IconButton(
                          onPressed: () => _selectThumbnail(pl, items),
                          tooltip: 'サムネイルを選ぶ',
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black54,
                            foregroundColor: Colors.white70,
                            shape: RoundedRectangleBorder(
                                borderRadius: AppRadius.borderSm),
                          ),
                          icon: const Icon(Icons.photo_camera,
                              size: AppIconSizes.s),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: AppSpacing.xl),
                // タイトル + 曲数 + ボタン
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              pl.name,
                              style: textTheme.titleLarge,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            onPressed: () => _renamePlaylist(pl),
                            tooltip: '名前を変更',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.edit,
                                size: AppIconSizes.sm,
                                color: AppTheme.muted(context)),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text('${items.length} 曲',
                          style: textTheme.bodyMedium
                              ?.copyWith(color: AppTheme.muted(context))),
                      // 自動で入れるタグ（タップで変更）
                      if ([
                        for (final t in tags)
                          if (pl.tagIds.contains(t.id)) t
                      ] case final autoTags when autoTags.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        InkWell(
                          borderRadius: AppRadius.borderSm,
                          onTap: () => _showTagPicker(pl),
                          child: Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Icon(Icons.autorenew,
                                  size: AppIconSizes.s,
                                  color: AppTheme.muted(context)),
                              for (final t in autoTags) TagChip(tag: t),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          if (items.isNotEmpty)
                            GreenButton(
                              icon: Icons.play_arrow_rounded,
                              label: '再生',
                              size: 38,
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => PlayerScreen(
                                    item: items.first,
                                    playlistItems: items,
                                    regionSelections:
                                        pl.regionSelections.isNotEmpty
                                            ? pl.regionSelections
                                            : null,
                                    disabledItemIds:
                                        pl.disabledItemIds.isNotEmpty
                                            ? pl.disabledItemIds
                                            : null,
                                    playlistName: pl.name,
                                    playlistId: pl.id,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(width: AppSpacing.md),
                          GlassPill(
                            active: pl.defaultShuffle,
                            tooltip: pl.defaultShuffle ? 'シャッフル再生' : '順に再生',
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg, vertical: 8),
                            onTap: () {
                              pl.defaultShuffle = !pl.defaultShuffle;
                              ref.read(playlistsProvider.notifier).update(pl);
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.shuffle,
                                    size: AppIconSizes.sm,
                                    color: pl.defaultShuffle
                                        ? AppTheme.accentGreen
                                        : null),
                                const SizedBox(width: AppSpacing.xs),
                                Text(
                                  'シャッフル',
                                  style: textTheme.labelSmall!.copyWith(
                                    color: pl.defaultShuffle
                                        ? AppTheme.accentGreen
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // トラック一覧（1 枚のガラス面）
          Expanded(
            child: items.isEmpty
                ? const EmptyHint(
                    icon: Icons.playlist_play,
                    iconSize: AppIconSizes.xxl,
                    title: '曲がありません',
                    subtitle: '＋ ボタンで追加',
                  )
                : GlassSurface(
              margin: EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg,
                  MediaQuery.of(context).viewPadding.bottom + AppSpacing.lg),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ReorderableListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 80),
              itemCount: items.length,
              // items は実体のないID（孤児）を除いた表示用リストなので、
              // itemIds の生インデックスではなくID経由で並べ替える
              onReorderItem: (oldIdx, newIdx) {
                final ids = items.map((e) => e.id).toList();
                ids.insert(newIdx, ids.removeAt(oldIdx));
                final orphans =
                    pl.itemIds.where((id) => !ids.contains(id)).toList();
                pl.itemIds = [...ids, ...orphans];
                ref.read(playlistsProvider.notifier).update(pl);
              },
              itemBuilder: (context, i) {
                final item = items[i];
                final itemTags =
                    tags.where((t) => item.tagIds.contains(t.id)).toList();
                final isDisabled = pl.disabledItemIds.contains(item.id);
                return Dismissible(
                  key: ValueKey('${pl.id}_${item.id}_$i'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: Colors.red,
                    child:
                        const Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  confirmDismiss: (_) => AppDialogs.confirmDelete(context,
                      message: '「${item.title}」をプレイリストから削除しますか？'),
                  onDismissed: (_) => _removeItem(pl, item.id),
                  child: Opacity(
                    opacity: isDisabled ? 0.4 : 1.0,
                    child: ListTile(
                      leading: GestureDetector(
                        onTap: () => ref
                            .read(playlistsProvider.notifier)
                            .toggleItemEnabled(pl.id, item.id),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: AppRadius.borderXs,
                              child: SizedBox(
                                width: 64,
                                height: 36,
                                child: ItemThumbnail(item: item, iconSize: AppIconSizes.sm),
                              ),
                            ),
                            if (isDisabled)
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius:
                                        AppRadius.borderXs,
                                  ),
                                  child: const Icon(Icons.block,
                                      color: Colors.white54, size: AppIconSizes.md),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // 同じサウンドトラックの曲などはサムネで見分けにくいので 2 行まで
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          decoration: isDisabled
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      subtitle: _buildSubtitle(item, itemTags, pl),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.more_vert,
                                size: AppIconSizes.md),
                            tooltip: 'メニュー',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _showItemMenu(pl, item, i),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              child: Icon(Icons.drag_handle,
                                  color: AppTheme.muted(context)),
                            ),
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  DetailScreen(itemId: item.id)),
                        );
                      },
                      onLongPress: () => _showItemMenu(pl, item, i),
                    ),
                  ),
                );
              },
                ),
              ),
            ),
          ),
        ],
      )),
      // キーボードが出ている間は出さない（list_screen と同じ理由）
      floatingActionButton: MediaQuery.viewInsetsOf(context).bottom > 0
          ? null
          : GreenButton(
              icon: Icons.playlist_add,
              size: 56,
              tooltip: '曲を追加',
              onPressed: () => _showAddDialog(pl),
            ),
    );
  }

  /// 「全体」を表す特殊ID（区間選択で全体再生を選ぶ用）
  static const _fullTrackId = '__full__';

  bool _hasItemRegions(LoopItem item) {
    final regions = item.effectiveRegions;
    return regions.isNotEmpty;
  }

  Widget? _buildSubtitle(LoopItem item, List<Tag> itemTags, Playlist pl) {
    final parts = <String>[];

    // 区間選択情報（「全体」も1区間としてカウント）
    if (_hasItemRegions(item)) {
      final allRegions = item.effectiveRegions;
      final totalCount = allRegions.length + 1; // +1 for 全体
      final sel = pl.regionSelections[item.id];
      if (sel != null && sel.isEmpty) {
        parts.add('0/$totalCount 区間（スキップ）');
      } else if (sel != null && sel.isNotEmpty) {
        parts.add('${sel.length}/$totalCount 区間');
      } else {
        // 未設定 = 全区間（全体は含まない）
        parts.add('${allRegions.length}/$totalCount 区間');
      }
    } else if (item.pointAMs > 0 || item.pointBMs > 0) {
      parts.add('AB設定あり');
    }

    if (item.speed != 1.0) parts.add('${item.speed}x');
    parts.addAll(item.musicInfoParts);

    final widgets = <Widget>[];
    if (parts.isNotEmpty) {
      widgets.add(Text(parts.join(' | '),
          style: Theme.of(context).textTheme.labelSmall));
    }
    if (itemTags.isNotEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Wrap(
          spacing: AppSpacing.xs,
          runSpacing: 2,
          children: [for (final t in itemTags) TagChip(tag: t, small: true)],
        ),
      ));
    }
    if (_hasItemRegions(item)) {
      widgets.add(
        GestureDetector(
          onTap: () => _showRegionEditSheet(pl, item),
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune, size: 12,
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: 0.6)),
                const SizedBox(width: 3),
                Text('区間を選択',
                    style: Theme.of(context).textTheme.labelSmall!.copyWith(
                        color: Theme.of(context).colorScheme.primary
                            .withValues(alpha: 0.6))),
              ],
            ),
          ),
        ),
      );
    }
    if (widgets.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  void _showRegionEditSheet(Playlist pl, LoopItem item) {
    final regions = item.effectiveRegions;
    final currentSel = pl.regionSelections[item.id];
    // キーが無い＝未設定（全区間を再生）／空リスト＝スキップ設定なので区別する。
    // 空リストを未設定扱いにすると、シートを開いて保存するだけで
    // スキップ設定が「全区間選択」に化けてしまう。
    final selected = currentSel != null
        ? Set<String>.from(currentSel)
        : regions.map((r) => r.id).toSet();

    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('区間を選択',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    TextButton(
                      onPressed: () {
                        ref
                            .read(playlistsProvider.notifier)
                            .updateRegionSelection(
                                pl.id, item.id, selected.toList());
                        Navigator.pop(ctx);
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ),
              // 「全体」オプション
              CheckboxListTile(
                value: selected.contains(_fullTrackId),
                onChanged: (v) {
                  setSheetState(() {
                    if (v == true) {
                      selected.add(_fullTrackId);
                    } else {
                      selected.remove(_fullTrackId);
                    }
                  });
                },
                title: Text('全体',
                    style: Theme.of(context).textTheme.bodyLarge),
                subtitle: Text('区間を使わず全体を再生',
                    style: Theme.of(context).textTheme.bodySmall),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const Divider(height: 1),
              // 各区間
              for (final region in regions)
                CheckboxListTile(
                  value: selected.contains(region.id),
                  onChanged: (v) {
                    setSheetState(() {
                      if (v == true) {
                        selected.add(region.id);
                      } else {
                        selected.remove(region.id);
                      }
                    });
                  },
                  title: Text(region.name,
                      style: Theme.of(context).textTheme.bodyLarge),
                  subtitle: region.hasPoints
                      ? Text(
                          '${TimeUtils.formatShortMs(region.pointAMs)}'
                          ' - '
                          '${TimeUtils.formatShortMs(region.pointBMs)}',
                          style: Theme.of(context).textTheme.bodySmall)
                      : null,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ),
      ),
    );
  }

}
