
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio/track_compatibility.dart';
import '../core/constants.dart';
import '../widgets/reorder_handle.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/selection_mark.dart';
import '../core/storage/app_boxes.dart';
import 'home/item_views.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/bulk_analysis_provider.dart';
import '../providers/data_provider.dart';
import '../providers/thumbnail_queue_provider.dart';
import '../services/audio_analysis_service.dart';
import '../services/save_flow.dart';
import '../services/share_service.dart';
import '../providers/thumb_tone_provider.dart';
import '../widgets/empty_hint.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/detail_split.dart';
import '../widgets/glass_surface.dart';
import '../widgets/item_thumbnail.dart';
import '../widgets/tag_chip.dart';
import '../widgets/now_playing_mark.dart';
import '../widgets/share_playlist_popup.dart';
import '../widgets/thumb_picker_sheet.dart';
import 'detail_screen.dart';
import 'player_screen.dart';
import 'playlist_item_picker_screen.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';
import '../core/utils/rate_label.dart';

enum _PlaylistMenu { share, saveAll, analyze, sortByCompatibility, delete }

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  /// 並べ替えモード（見出しのボタンでオンオフ）: ⋮ の場所に ≡ が出て触れてすぐ動かせ、
  /// 行の長押しでも持ち上がる。ふだんは並べ替えを出さない（意図せず順番を変えないように）。
  /// 変更はその場で保存するので「保存」は無い
  bool _reordering = false;

  /// 複数選択（行の長押しで入る。タップで切り替え、0 件になったら抜ける）。
  /// 見出しが「全選択・外す・やめる」に入れ替わる
  final _selectedIds = <String>{};

  void _toggleSelect(String itemId) {
    setState(() {
      if (!_selectedIds.remove(itemId)) _selectedIds.add(itemId);
    });
  }

  /// 曲の一覧をリスト小（曲名 1 行だけ）で出す。ふだんはリスト大（曲名 2 行 + 情報 + タグ）
  bool _compact = AppBoxes.settings
      .get(SettingsKeys.playlistDetailCompact, defaultValue: false) as bool;

  void _toggleCompact() {
    setState(() => _compact = !_compact);
    AppBoxes.settings.put(SettingsKeys.playlistDetailCompact, _compact);
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

    SharePlaylistPopup.show(
      context,
      name: pl.name,
      songCount: youtubeItems.length,
      url: url,
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

  void _removeItem(Playlist pl, String itemId) => _removeItems(pl, {itemId});

  /// 確認なしで外す。通知の「元に戻す」で同じ位置に戻せる
  Future<void> _removeItems(Playlist pl, Set<String> ids) async {
    if (ids.isEmpty) return;
    final itemIds = List<String>.from(pl.itemIds);
    final regions = {for (final id in ids) id: ?pl.regionSelections[id]};
    final String what;
    if (ids.length == 1) {
      final title = ref
              .read(loopItemsProvider)
              .where((i) => i.id == ids.first)
              .firstOrNull
              ?.title ??
          '曲';
      what = '「$title」';
    } else {
      what = '${ids.length} 曲';
    }
    final notifier = ref.read(playlistsProvider.notifier);
    for (final id in ids) {
      await notifier.removeItem(pl.id, id);
    }
    AppToast.instance
      ..hide()
      ..show(AppSnackBar.action(
        '$whatをプレイリストから外しました',
        label: '元に戻す',
        onPressed: () {
          final current = ref
              .read(playlistsProvider)
              .where((p) => p.id == pl.id)
              .firstOrNull;
          if (current == null) return;
          current.itemIds = itemIds;
          // 戻した曲は手で足した曲として残す（タグで自動に外した印は消す）
          current.excludedItemIds.removeAll(ids);
          current.regionSelections.addAll(regions);
          ref.read(playlistsProvider.notifier).update(current);
        },
      ));
  }

  /// 行の ⋮ から。行の脇（[anchor]）に出す。スワイプでしかできなかった「外す」と、
  /// サムネのタップでしかできなかった有効・無効もここに置く
  void _showItemMenu(Playlist pl, LoopItem item, int index,
      {BuildContext? anchor}) {
    final disabled = pl.disabledItemIds.contains(item.id);
    AppSheets.actions(
      context,
      anchor: anchor,
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
        thumbOf: (tag) => tag.thumbItemOf(allItems));
    if (result == null || !mounted) return;
    final notifier = ref.read(playlistsProvider.notifier);
    final before = pl.itemIds.length;
    await notifier.setTags(pl.id, result);
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
        result.isEmpty
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

    // 横画面は AppBar を置かず、左の列の上に「プレイリスト」の行（戻る・編集・その他）を
    // 置く。右の曲の一覧は画面の上まで使う
    final split = DetailSplit.of(MediaQuery.sizeOf(context));
    // 選んでいる曲（一覧から消えた曲は数えない）
    final selectedIds = {
      for (final i in items)
        if (_selectedIds.contains(i.id)) i.id
    };
    final selecting = selectedIds.isNotEmpty;
    final screenTitle = selecting ? '${selectedIds.length} 曲を選択' : 'プレイリスト';
    final actions = <Widget>[
      // 複数選択中は選択の操作だけ
      if (selecting) ...[
        IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: '全選択',
          onPressed: () =>
              setState(() => _selectedIds.addAll(items.map((i) => i.id))),
        ),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
          tooltip: 'プレイリストから外す',
          onPressed: () {
            setState(_selectedIds.clear);
            _removeItems(pl, selectedIds);
          },
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: '選択をやめる',
          onPressed: () => setState(_selectedIds.clear),
        ),
      ] else if (items.isNotEmpty) ...[
        // 今の表示のアイコン（ホームの曲一覧と同じ）。押すとリスト大 ⇔ リスト小。
        // 並べ替えモード中も使える（行の高さを変えて並べ替えやすくできる）
        IconButton(
          icon: Icon(
              (_compact ? ItemViewMode.list : ItemViewMode.titles).icon),
          tooltip:
              '表示: ${(_compact ? ItemViewMode.list : ItemViewMode.titles).label}',
          onPressed: _toggleCompact,
        ),
        // 並べ替えモード（オンの間は緑。同じボタンで抜ける）
        IconButton(
          icon: const Icon(Icons.swap_vert),
          color: _reordering ? AppTheme.accentGreen : null,
          tooltip: _reordering ? '並べ替えを終える' : '並べ替え',
          onPressed: () => setState(() => _reordering = !_reordering),
        ),
      ],
      if (!selecting)
        ReorderDim(
          reordering: _reordering,
          hide: true,
          child: PopupMenuButton<_PlaylistMenu>(
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
            final restoring =
                ref.read(thumbnailQueueProvider)?.running ?? false;
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
                enabled: unanalyzed > 0 && bulk == null && !restoring,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.music_note),
                  title: const Text('テンポ/キーをまとめて解析'),
                  subtitle: Text(bulk != null
                      ? '解析中 ${bulk.index} / ${bulk.total}'
                      : restoring
                          ? 'サムネイルの取得中は使えません'
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
        ),
    ];
    // 表紙: 一覧と同じ曲の束（正方形のサムネの上に板 2 枚、左下に曲数の札）+ 右上に写真ボタン。
    // [size] は表紙の幅（縦は小さく、横は大きく）。並べ替えモード中は暗くして触れない
    Widget cover(double size) => ReorderDim(
      reordering: _reordering,
      child: SizedBox(
        width: size,
        child: PlaylistCover(
          radius: 14,
          count: items.length,
          image: thumbItem != null
              ? ItemThumbnail(item: thumbItem, iconSize: AppIconSizes.sm)
              : Container(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.08),
                  child: Icon(Icons.playlist_play,
                      color: AppTheme.muted(context), size: 40),
                ),
          overlays: [
            if (items.isNotEmpty)
              Positioned(
                right: 2,
                top: 2,
                child: ReorderDim(
                  reordering: _reordering,
                  hide: true,
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
              ),
          ],
        ),
      ),
    );
    // タイトル + 自動で入れるタグ（曲数は表紙の札）
    final titleBlock = <Widget>[
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
          ReorderDim(
            reordering: _reordering,
            hide: true,
            child: IconButton(
              onPressed: () => _renamePlaylist(pl),
              tooltip: '名前を変更',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.edit,
                  size: AppIconSizes.sm,
                  color: AppTheme.muted(context)),
            ),
          ),
        ],
      ),
      // 自動で入れるタグ（タップで変更）。無いときも同じ場所に入口を出す
      // （0 件にしたあと、どこから付け直すのか分からなくなる）
      const SizedBox(height: AppSpacing.sm),
      InkWell(
        borderRadius: AppRadius.borderSm,
        onTap: () => _showTagPicker(pl),
        child: switch ([
          for (final t in tags)
            if (pl.tagIds.contains(t.id)) t
        ]) {
          [] => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.label_outline,
                    size: AppIconSizes.s, color: AppTheme.muted(context)),
                const SizedBox(width: AppSpacing.xs),
                Text('タグを紐づける',
                    style: textTheme.labelSmall
                        ?.copyWith(color: AppTheme.muted(context))),
              ],
            ),
          final autoTags => Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [for (final t in autoTags) TagChip(tag: t)],
            ),
        },
      ),
    ];
    // 再生・シャッフル（表紙の右に縦に 2 つ、幅いっぱい）
    final buttons = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isNotEmpty) ...[
          GreenButton(
            icon: Icons.play_arrow_rounded,
            label: '再生',
            size: _headerButtonHeight,
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
          const SizedBox(height: AppSpacing.md),
        ],
        GlassPill(
          active: pl.defaultShuffle,
          tooltip: pl.defaultShuffle ? 'シャッフル再生' : '順に再生',
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: 10),
          onTap: () {
            pl.defaultShuffle = !pl.defaultShuffle;
            ref.read(playlistsProvider.notifier).update(pl);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
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
    );
    // 並べ替えモード中: 名前・曲数・タグは暗くして触れなくし、再生・シャッフルは隠す（場所は残す）
    Widget titleArea(CrossAxisAlignment align) => ReorderDim(
          reordering: _reordering,
          child: Column(crossAxisAlignment: align, children: titleBlock),
        );
    final playButtons =
        ReorderDim(reordering: _reordering, hide: true, child: buttons);
    // 表紙の右に再生・シャッフル、名前とタグは表紙の下（[coverSize] は縦と横で変える）
    Widget headerBody(double coverSize) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                cover(coverSize),
                const SizedBox(width: AppSpacing.xl),
                Expanded(child: playButtons),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            titleArea(CrossAxisAlignment.start),
          ],
        );
    final tallHeader = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: headerBody(_coverSize),
    );
    // 横: 上に「プレイリスト」の行、その下に縦と同じ並びを大きめの表紙で。
    // 正方形の表紙を列の幅いっぱいにすると、横画面の高さに収まらない
    final splitHeader = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSplitTopBar(title: screenTitle, actions: actions),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: headerBody(_coverSizeWide),
        ),
      ],
    );

    return PopScope(
      // 選択中・並べ替えモード中の「戻る」はそれを終えるだけ（画面は閉じない）
      canPop: !_reordering && !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          if (selecting) {
            _selectedIds.clear();
          } else {
            _reordering = false;
          }
        });
      },
      child: GlassScaffold(
      // ガラス風: 背景（サムネの色味）を AppBar の裏まで通す
      tone: tone,
      title: Text(screenTitle, style: textTheme.titleMedium),
      showAppBar: !split,
      actions: actions,
      // 本文の上端は bodyBuilder の context から（AppBar の高さが入る）
      bodyBuilder: (bodyContext) => SafeArea(
        top: false,
        bottom: false,
        child: _DetailLayout(
          top: MediaQuery.paddingOf(bodyContext).top + AppSpacing.xs,
          // ヘッダー（横は左の列に縦に積む）
          header: split ? splitHeader : tallHeader,
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
                // 自動で入れるタグが 1 つだけなら、どの曲にも付いているので出さない
                // （2 つ以上なら、どれで入ったかが分かるように出す）
                final onlyAutoTag =
                    pl.tagIds.length == 1 ? pl.tagIds.first : null;
                final itemTags = tags
                    .where((t) =>
                        item.tagIds.contains(t.id) && t.id != onlyAutoTag)
                    .toList();
                final isDisabled = pl.disabledItemIds.contains(item.id);
                final isSelected = selectedIds.contains(item.id);
                return KeyedSubtree(
                  key: ValueKey('${pl.id}_${item.id}_$i'),
                  child: SelectionDim(
                    selecting: selecting,
                    selected: isSelected,
                    // 並べ替えモードは行に触れるとほぼすぐ持ち上がる。
                    // メニューは行の脇に出すので、行の context を取る
                    child: Builder(builder: (row) => ReorderRowListener(
                      index: i,
                      enabled: _reordering,
                      child: Opacity(
                    opacity: isDisabled || item.isUnplayable ? 0.4 : 1.0,
                    child: ListTile(
                      selected: isSelected,
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                        // サムネのタップで有効・無効（選択中・並べ替え中は行の操作に任せる）
                        onTap: selecting || _reordering
                            ? null
                            : () => ref
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
                        maxLines: _compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyLarge?.copyWith(
                          decoration: isDisabled
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      // リスト小は曲名だけ（再生できない知らせは残す）
                      subtitle: _compact
                          ? (item.isUnplayable
                              ? Text('再生できないので飛ばします',
                                  style: textTheme.labelSmall)
                              : null)
                          : _buildSubtitle(item, itemTags, pl),
                      // ふだんは ⋮、並べ替えモードは同じ場所が ≡（触れてすぐ動かせる）、
                      // 選択中は選択の印。右に余白は取らない（曲名を広く出す）
                      trailing: SelectionTrailing(
                        selecting: selecting,
                        selected: isSelected,
                        child: _reordering
                            ? SizedBox(
                                width: _trailingButtonSize,
                                height: _trailingButtonSize,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    const ReorderHandleIcon(),
                                    Positioned.fill(
                                        child: ReorderHandle.area(index: i)),
                                  ],
                                ),
                              )
                            // ⋮ の上を長押ししても行の選択になるように
                            : ItemInnerButtons(
                                child: IconButton(
                                  icon: const Icon(Icons.more_vert,
                                      size: AppIconSizes.md),
                                  tooltip: 'メニュー',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () =>
                                      _showItemMenu(pl, item, i, anchor: row),
                                ),
                              ),
                      ),
                      // タップ = 開く（選択中は選択の切り替え）、長押し = 選択。
                      // 並べ替えモード中はどちらもしない
                      onTap: _reordering
                          ? null
                          : () {
                              if (selecting) {
                                _toggleSelect(item.id);
                                return;
                              }
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        DetailScreen(itemId: item.id)),
                              );
                            },
                      onLongPress:
                          _reordering ? null : () => _toggleSelect(item.id),
                    ),
                  ),
                    )),
                  ),
                );
              },
                ),
              ),
            ),
        )),
      // キーボードが出ている間は出さない（list_screen と同じ理由）。並べ替えモード中も
      floatingActionButton:
          MediaQuery.viewInsetsOf(context).bottom > 0 || _reordering
          ? null
          : ToastObstacle(
              child: GreenButton(
                icon: Icons.playlist_add,
                size: 56,
                tooltip: '曲を追加',
                onPressed: () => _showAddDialog(pl),
              ),
            ),
    ),
    );
  }

  /// 行の右端のボタン（⋮・≡）の大きさ（VisualDensity.compact の IconButton と同じ）
  static const double _trailingButtonSize = 40;

  /// 見出しの表紙（正方形）の幅。縦と、横の左の列
  static const double _coverSize = 112;
  static const double _coverSizeWide = 150;

  /// 表紙の右の再生ボタンの高さ
  static const double _headerButtonHeight = 44;

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

    if (item.speed != 1.0) parts.add(rateLabel(item.speed));
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

    AppSheets.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.lg),
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
              // 各区間（多いときは中で流れる）
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
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
                  ],
                ),
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
/// ヘッダーで高さが埋まり、曲が 1〜2 行しか見えなかった）。左は収まらなければスクロール。
/// 横は AppBar を置かない（ヘッダーの上に同じ行がある）ので、[top] は状態バーの下
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (!DetailSplit.of(size)) {
      return Column(
        children: [
          SizedBox(height: top),
          header,
          progress,
          Expanded(child: list),
        ],
      );
    }
    final side = DetailSplit.sideWidth(size);
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
