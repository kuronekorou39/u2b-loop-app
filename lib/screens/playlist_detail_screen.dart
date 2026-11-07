
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
import '../providers/bulk_analysis_provider.dart';
import '../providers/data_provider.dart';
import '../services/audio_analysis_service.dart';
import '../services/save_flow.dart';
import '../services/share_service.dart';
import '../providers/thumb_tone_provider.dart';
import '../widgets/empty_hint.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/glass_surface.dart';
import '../widgets/item_thumbnail.dart';
import '../widgets/tag_chip.dart';
import '../widgets/now_playing_mark.dart';
import '../widgets/thumb_picker_sheet.dart';
import 'detail_screen.dart';
import 'player_screen.dart';
import 'playlist_item_picker_screen.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';

enum _PlaylistMenu { share, saveAll, analyze, sortByCompatibility, delete }

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  /// 編集モード: 並べ替え（右の ≡）と外す（⊖・スワイプ。確認なし、通知の「元に戻す」で戻せる）。
  /// ふだんは並べ替え・スワイプを出さない（意図せず順番を変えたり外したりしないように）。
  /// 変更はその場で保存するので「保存」は無い
  bool _editing = false;

  /// 削除ボタンで外している途中の曲（横に抜けて縮むアニメーションのあとで外す）
  final _removing = <String>{};

  /// 削除ボタン: スワイプで外したときと同じく、横に抜けて縮んでから外す
  void _removeWithAnimation(String itemId) {
    if (_removing.contains(itemId)) return;
    setState(() => _removing.add(itemId));
  }
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

  void _toast(AppToastMessage bar) {
    if (mounted) AppToast.instance.show(bar);
  }

  /// 未解析の曲を 1 曲ずつ順に解析する。裏で動かし、進み具合は曲一覧の上に出す
  /// （解析中も並べ替え・タグの編集・解析が済んだ曲の再生ができる）
  void _analyzeUnanalyzed(Playlist pl, List<LoopItem> items) {
    final targets = AudioAnalysisService.unanalyzed(items);
    if (targets.isEmpty) {
      _toast(AppSnackBar.info('すべて解析済みです'));
      return;
    }
    if (!ref.read(bulkAnalysisProvider.notifier).start(pl.id, targets)) {
      _toast(AppSnackBar.info('ほかのプレイリストを解析中です'));
    }
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
      AppToast.instance.show(
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
      AppToast.instance.show(
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
            AppToast.instance.show(
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
    ThumbPickerSheet.show(
      context,
      items: items,
      currentId: pl.effectiveThumbnailItemId,
      custom: pl.thumbnailItemId != null,
      resetLabel: 'デフォルトに戻す（1曲目）',
      onPick: (id) =>
          ref.read(playlistsProvider.notifier).setThumbnailItem(pl.id, id),
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
    AppToast.instance
      ..hide()
      ..show(AppSnackBar.action(
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
            AppToast.instance.show(AppSnackBar.success(
                disabled ? '「${item.title}」を再生に含めます' : '「${item.title}」をスキップします'));
          },
        ),
        SheetAction(
          icon: Icons.playlist_remove,
          label: 'プレイリストから外す',
          destructive: true,
          // 確認は出さない（通知の「元に戻す」で戻せる）
          onTap: () => _removeItem(pl, item.id),
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
            AppToast.instance.show(
              AppSnackBar.success('${ids.length}件を追加しました'),
            );
          },
        ),
      ),
    );
  }

  /// 再生に含める曲をまとめて保存（曲全体）。アプリ内に保存済みの曲は飛ばす
  Future<void> _saveAll(Playlist pl, List<LoopItem> items) async {
    final targets =
        items.where((i) => !pl.disabledItemIds.contains(i.id)).toList();
    final choice = await SaveFlow.showSheet(context,
        title: '${pl.name}（${targets.length} 曲）を保存',
        offline: targets.any(SaveFlow.canSaveOffline));
    if (choice == null || !mounted) return;
    await SaveFlow.runBulk(context, ref, items: targets, choice: choice);
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
    AppToast.instance.show(AppSnackBar.success(
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

    return PopScope(
      // 編集モード中の「戻る」は編集を終えるだけ（画面は閉じない）
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) setState(() => _editing = false);
      },
      child: GlassScaffold(
      // ガラス風: 背景（サムネの色味）を AppBar の裏まで通す
      tone: tone,
      title: Text('プレイリスト', style: textTheme.titleMedium),
      actions: [
          // 編集モードは「完了」だけ（同じ場所に「編集」と入れ替わる）
          if (_editing)
            TextButton.icon(
              onPressed: () => setState(() => _editing = false),
              icon: const Icon(Icons.check, size: AppIconSizes.sm),
              label: const Text('完了'),
              style: TextButton.styleFrom(foregroundColor: AppTheme.accentGreen),
            )
          else if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.edit_note),
              tooltip: '編集（並べ替え・外す）',
              onPressed: () => setState(() => _editing = true),
            ),
          if (!_editing)
            PopupMenuButton<_PlaylistMenu>(
              tooltip: 'その他',
              onSelected: (m) => switch (m) {
                _PlaylistMenu.share => _sharePlaylist(pl, items),
                _PlaylistMenu.saveAll => _saveAll(pl, items),
                _PlaylistMenu.analyze => _analyzeUnanalyzed(pl, items),
                _PlaylistMenu.sortByCompatibility =>
                  _sortByCompatibility(pl, items),
                _PlaylistMenu.delete => _deletePlaylist(pl),
              },
              itemBuilder: (_) {
                final unanalyzed = AudioAnalysisService.unanalyzed(items).length;
                final bulk = ref.read(bulkAnalysisProvider);
                return [
                  if (items.isNotEmpty) ...[
                  const PopupMenuItem(
                    value: _PlaylistMenu.share,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.share_outlined),
                      title: Text('共有'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: _PlaylistMenu.saveAll,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.download_outlined),
                      title: Text('まとめて保存'),
                      subtitle: Text('アプリ内に保存 / 端末に書き出し'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _PlaylistMenu.analyze,
                    // 動いている間は 2 つ目を始めない（音声のダウンロードが詰まる）
                    enabled: unanalyzed > 0 && bulk == null,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.music_note),
                      title: const Text('テンポ/キーをまとめて解析'),
                      subtitle: Text(bulk != null
                          ? '解析中 ${bulk.index} / ${bulk.total}'
                          : unanalyzed > 0
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
                  const PopupMenuDivider(),
                  ],
                  const PopupMenuItem(
                    value: _PlaylistMenu.delete,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline, color: Colors.redAccent),
                      title: Text('プレイリストを削除',
                          style: TextStyle(color: Colors.redAccent)),
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
        child: _DetailLayout(
          top: MediaQuery.paddingOf(bodyContext).top + AppSpacing.xs,
          // ヘッダー
          header: Padding(
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
                      // 横画面の左の列は狭いので、入りきらなければ折り返す
                      Wrap(
                        spacing: AppSpacing.md,
                        runSpacing: AppSpacing.md,
                        crossAxisAlignment: WrapCrossAlignment.center,
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
          // まとめて解析の進み具合（このプレイリストで動いているときだけ）
          progress: _BulkAnalysisCard(playlistId: pl.id),
          // トラック一覧（1 枚のガラス面）
          list: items.isEmpty
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
              // 並べ替えは編集モードの ≡ だけ（長押しで動き出さないように）
              buildDefaultDragHandles: false,
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
                  // スワイプで外すのは編集モードだけ（確認なし。通知の「元に戻す」で戻せる）
                  direction: _editing
                      ? DismissDirection.endToStart
                      : DismissDirection.none,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: Colors.red,
                    child:
                        const Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  onDismissed: (_) => _removeItem(pl, item.id),
                  child: _SlideAway(
                    active: _removing.contains(item.id),
                    onDone: () {
                      _removing.remove(item.id);
                      _removeItem(pl, item.id);
                    },
                    // 編集モードは行の長押しでも持ち上げて並べ替えられる
                    child: ReorderableDelayedDragStartListener(
                      index: i,
                      enabled: _editing,
                      child: Opacity(
                    opacity: isDisabled || item.isUnplayable ? 0.4 : 1.0,
                    child: ListTile(
                      // 編集モードは左端につまみ（≡）
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_editing)
                            ReorderableDragStartListener(
                              index: i,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                    right: AppSpacing.md,
                                    top: AppSpacing.sm,
                                    bottom: AppSpacing.sm),
                                child: Icon(Icons.drag_handle,
                                    color: AppTheme.muted(context)),
                              ),
                            ),
                          GestureDetector(
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
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ItemThumbnail(item: item, iconSize: AppIconSizes.sm),
                                    NowPlayingMark(itemId: item.id, size: 14),
                                  ],
                                ),
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
                        ],
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
                      // ふだんは ⋮、編集モードは同じ場所が ⊖（外す）。右に余白は取らない
                      // （曲名を広く出す）
                      trailing: _editing
                          ? IconButton(
                              icon: const Icon(Icons.remove_circle_outline,
                                  size: AppIconSizes.md, color: Colors.redAccent),
                              tooltip: 'プレイリストから外す',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _removeWithAnimation(item.id),
                            )
                          : IconButton(
                              icon: const Icon(Icons.more_vert,
                                  size: AppIconSizes.md),
                              tooltip: 'メニュー',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _showItemMenu(pl, item, i),
                            ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  DetailScreen(itemId: item.id)),
                        );
                      },
                      onLongPress:
                          _editing ? null : () => _showItemMenu(pl, item, i),
                    ),
                  ),
                    ),
                  ),
                );
              },
                ),
              ),
            ),
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
    if (item.isUnplayable) parts.add('再生できないので飛ばします');

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
    if (ref.watch(bulkAnalysisProvider)?.currentId == item.id) {
      parts.add('テンポ/キーを解析中…');
    } else {
      parts.addAll(item.musicInfoParts);
    }

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

/// プレイリスト詳細の並べ方。縦は上からヘッダー・進み具合・曲の一覧。
/// 横（幅が足りるとき）は左にヘッダーと進み具合、右に曲の一覧（縦のままだと
/// ヘッダーで高さが埋まり、曲が 1〜2 行しか見えなかった）。左は収まらなければスクロール
class _DetailLayout extends StatelessWidget {
  const _DetailLayout({
    required this.top,
    required this.header,
    required this.progress,
    required this.list,
  });

  /// 本文の上端（AppBar の下）
  final double top;
  final Widget header;
  final Widget progress;
  final Widget list;

  /// 横で左右に分ける最小の幅と、左の列の幅
  static const splitMinWidth = 600.0;
  static const sideMin = 320.0;
  static const sideMax = 420.0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final split = size.width > size.height && size.width >= splitMinWidth;
    if (!split) {
      return Column(
        children: [
          SizedBox(height: top),
          header,
          progress,
          Expanded(child: list),
        ],
      );
    }
    final side = (size.width * 0.38).clamp(sideMin, sideMax).toDouble();
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: side,
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom +
                      AppSpacing.lg),
              child: Column(children: [header, progress]),
            ),
          ),
          Expanded(child: list),
        ],
      ),
    );
  }
}

/// まとめて解析の進み具合（曲一覧の上）。閉じられない板で、中止だけできる
class _BulkAnalysisCard extends ConsumerWidget {
  const _BulkAnalysisCard({required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(bulkAnalysisProvider);
    if (s == null || s.playlistId != playlistId) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return GlassSurface(
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('テンポ/キーを解析中',
                        style: textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('${s.index} / ${s.total}', style: textTheme.labelSmall),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                LinearProgressIndicator(value: s.index / s.total),
                const SizedBox(height: AppSpacing.xs),
                Text(s.currentTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall
                        ?.copyWith(color: AppTheme.muted(context))),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          TextButton(
            onPressed: s.stopping
                ? null
                : () => ref.read(bulkAnalysisProvider.notifier).stop(),
            child: Text(s.stopping ? 'この曲で止めます' : '中止'),
          ),
        ],
      ),
    );
  }
}

/// 削除ボタンで外す行: スワイプで外したとき（Dismissible）と同じく、赤い面の上を左へ抜け、
/// 縮んでから [onDone]（そこで実際に外す）。[active] になったら始める
class _SlideAway extends StatefulWidget {
  const _SlideAway({required this.active, required this.onDone, required this.child});

  final bool active;
  final VoidCallback onDone;
  final Widget child;

  @override
  State<_SlideAway> createState() => _SlideAwayState();
}

class _SlideAwayState extends State<_SlideAway> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  // 前半で横に抜け、後半で縮む
  late final _slide = Tween(begin: Offset.zero, end: const Offset(-1, 0)).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0, 0.55, curve: Curves.easeIn)));
  late final _size = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.55, 1, curve: Curves.easeOut)));

  @override
  void didUpdateWidget(_SlideAway old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _controller.forward().then((_) {
        if (mounted) widget.onDone();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active && !_controller.isAnimating) return widget.child;
    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              color: Colors.red,
              child: const Icon(Icons.delete_outline, color: Colors.white),
            ),
          ),
          SlideTransition(position: _slide, child: widget.child),
        ],
      ),
    );
  }
}
