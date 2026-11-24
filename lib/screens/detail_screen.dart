import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/audio/musical_key.dart';
import '../core/audio/tempo_sections.dart';
import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../core/utils/id_generator.dart';
import '../models/loop_item.dart';
import '../models/playlist.dart';
import '../models/tag.dart';
import '../providers/bulk_analysis_provider.dart';
import '../providers/data_provider.dart';
import '../providers/thumbnail_queue_provider.dart';
import '../providers/player_provider.dart';
import '../services/audio_analysis_service.dart';
import '../services/save_flow.dart';
import '../providers/thumb_tone_provider.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/detail_split.dart';
import '../widgets/glass_surface.dart';
import '../widgets/item_tag_sheet.dart';
import '../widgets/item_thumbnail.dart';
import '../widgets/loop/region_time_dialog.dart';
import '../widgets/similar_tracks_sheet.dart';
import '../widgets/tag_chip.dart';
import '../widgets/tempo_key_sheet.dart';
import 'player_screen.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_sheets.dart';
import '../core/utils/rate_label.dart';

class DetailScreen extends ConsumerStatefulWidget {
  final String itemId;

  const DetailScreen({super.key, required this.itemId});

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _memoController;
  bool _initialized = false;
  bool _analyzing = false;
  bool _fetchingThumb = false;

  void _initControllers(LoopItem item) {
    if (!_initialized) {
      _titleController = TextEditingController(text: item.title);
      _memoController = TextEditingController(text: item.memo ?? '');
      _initialized = true;
    }
  }

  @override
  void dispose() {
    if (_initialized) {
      _titleController.dispose();
      _memoController.dispose();
    }
    super.dispose();
  }

  bool _hasChanges(LoopItem item) {
    if (!_initialized) return false;
    return _titleController.text.trim() != item.title ||
        _memoController.text.trim() != (item.memo ?? '');
  }

  /// 入力内容を保存する（画面は閉じない）。保存できたらtrue。
  Future<bool> _saveOnly(LoopItem item) async {
    final title = _titleController.text.trim();
    final memo = _memoController.text.trim();
    if (title.isEmpty) return false;

    item.title = title;
    item.memo = memo.isEmpty ? null : memo;
    await ref.read(loopItemsProvider.notifier).update(item);
    return true;
  }

  Future<void> _save(LoopItem item) async {
    if (!await _saveOnly(item)) return;
    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() => AppDialogs.confirm(context,
      title: '変更を破棄しますか？',
      message: '保存していない変更があります。',
      confirmLabel: '破棄',
      cancelLabel: '戻る',
      destructive: true);

  /// 再生できない理由と「もう一度試す」（理由を消して開き直す。開けなければまた残る）
  Widget _buildUnplayableNotice(LoopItem item) {
    final textTheme = Theme.of(context).textTheme;
    return GlassSurface(
      tint: Colors.orange.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl, AppSpacing.lg, AppSpacing.lg, AppSpacing.lg),
      child: Row(
        children: [
          const Icon(Icons.block, color: Colors.orange, size: AppIconSizes.md),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('再生できない動画（プレイリストでは飛ばします）',
                    style: textTheme.titleSmall?.copyWith(color: Colors.orange)),
                const SizedBox(height: AppSpacing.xs),
                Text(item.unplayableReason!, style: textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          TextButton(
            onPressed: () async {
              await ref.read(loopItemsProvider.notifier).setUnplayable(item.id, null);
              if (mounted) _openPlayer(item);
            },
            child: const Text('もう一度試す'),
          ),
        ],
      ),
    );
  }

  Future<void> _openPlayer(LoopItem item) async {
    if (_hasChanges(item)) await _saveOnly(item);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(item: item)),
    );
  }

  /// この曲のサムネイルだけ取る（まとめて取得を一時停止していても通る）
  Future<void> _fetchThumbnail(LoopItem item) async {
    setState(() => _fetchingThumb = true);
    final ok = await ref.read(thumbnailQueueProvider.notifier).fetchNow(item.id);
    if (!mounted) return;
    setState(() => _fetchingThumb = false);
    if (!ok) {
      AppToast.instance.show(AppSnackBar.error('サムネイルを取得できませんでした'));
    }
  }

  /// 音声を取得してテンポ/キーを解析する（再生せずに単独で）
  Future<void> _analyze(LoopItem item) async {
    if (ref.read(thumbnailQueueProvider)?.running ?? false) {
      AppToast.instance.show(AppSnackBar.info('サムネイルの取得が終わってから解析してください'));
      return;
    }
    // まとめて解析がちょうどこの曲を解析中なら、終わるのを待ってもらう（二重に落とさない）
    if (ref.read(bulkAnalysisProvider)?.currentId == item.id) {
      AppToast.instance.show(
          AppSnackBar.info('まとめて解析でこの曲を解析中です'));
      return;
    }
    setState(() => _analyzing = true);
    final result = await AudioAnalysisService.analyzeItem(
      ref.read(loopItemsProvider.notifier),
      ref.read(youtubeServiceProvider),
      item,
    );
    if (!mounted) return;
    setState(() => _analyzing = false);
    final messenger = AppToast.instance;
    if (result == null && AudioAnalysisService.isTooLong(item)) {
      messenger.show(AppSnackBar.info(
          '${AudioAnalysisService.maxAnalyzableMinutes} 分以上の曲は解析しません。タップして手入力できます'));
    } else if (result == null) {
      messenger.show(AppSnackBar.error('テンポ/キーを解析できませんでした'));
    } else if (result.span.isMusic && !result.span.steadyBeat) {
      messenger.show(AppSnackBar.success(
          '解析完了: テンポ不定（一定の拍がない曲）${result.key == null ? '' : ' · ${MusicalKey.display(result.key)}'}'));
    } else if (!result.span.isMusic) {
      messenger.show(AppSnackBar.info(
          '曲ではないと判定しました（拍が見つかりません）。タップして手入力できます'));
    } else if (result.bpm == null && result.key == null) {
      messenger.show(
          AppSnackBar.info('テンポ/キーを検出できませんでした。タップして手入力できます'));
    } else {
      messenger.show(
          AppSnackBar.success(
              '解析完了: ${_tempoKeyText(result.bpm, result.key, result.sections)}'));
    }
  }

  String _tempoKeyText(double? bpm, String? key, List<TempoSection> sections,
      {bool noSteadyBeat = false}) {
    final parts = <String>[
      if (bpm != null) LoopItem.formatBpm(bpm, sections) else if (noSteadyBeat) 'テンポ不定',
      if (key != null) MusicalKey.display(key)!,
    ];
    return parts.isEmpty ? '検出できず' : parts.join(' · ');
  }

  /// 「テンポ / キー」と「つなぎやすい曲」を 1 行に並べる。説明は出さず値だけ
  /// （テンポの区切りなどの細かい値はタップで開くシートに）
  Widget _buildMusicRow(LoopItem item) {
    final unanalyzed =
        item.analyzedAt == null && item.bpm == null && item.musicalKey == null;
    final analyzed = item.bpm != null || item.musicalKey != null;
    // 長い曲（ミックス音源など）は解析しない。タップで手入力のシート
    final tooLong = unanalyzed && AudioAnalysisService.isTooLong(item);
    final restoring =
        ref.watch(thumbnailQueueProvider.select((s) => s?.running ?? false));
    final value = _analyzing
        ? '解析中…'
        : unanalyzed
            ? '未解析'
            : item.notMusic == true && !analyzed
                ? '曲ではない'
                : _tempoKeyText(item.bpm, item.musicalKey, item.tempoSections,
                    noSteadyBeat: item.noSteadyBeat == true);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _MusicTile(
              icon: Icons.speed,
              text: value,
              onTap: _analyzing || (restoring && unanalyzed && !tooLong)
                  ? null
                  : () => unanalyzed && !tooLong
                      ? _analyze(item)
                      : TempoKeySheet.show(context,
                          item: item, onReanalyze: () => _analyze(item)),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // 解析済みなら、ライブラリからつなぎやすい曲を探せる（未解析の間は押せない）
          Expanded(
            child: _MusicTile(
              icon: Icons.join_inner,
              text: 'つなぎやすい曲',
              onTap: analyzed ? () => _showSimilarTracks(item) : null,
            ),
          ),
        ],
      ),
    );
  }

  void _showSimilarTracks(LoopItem item) {
    SimilarTracksSheet.show(
      context,
      target: item,
      candidates: ref.read(loopItemsProvider),
      onSelect: (other) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailScreen(itemId: other.id)),
      ),
    );
  }

  Future<void> _duplicateItem(LoopItem item) async {
    if (_hasChanges(item)) await _saveOnly(item);
    final copy =
        await ref.read(loopItemsProvider.notifier).duplicate(item);
    if (mounted) {
      AppToast.instance.show(
        AppSnackBar.success('複製しました'),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => DetailScreen(itemId: copy.id)),
      );
    }
  }

  void _showAddToPlaylist(LoopItem item) {
    final playlists = ref.read(playlistsProvider);
    // 件数が多くても流れる共通シート。すでに入っているものは印を付けて選べない
    AppSheets.actions(
      context,
      title: 'プレイリストに追加',
      note: playlists.isEmpty ? 'プレイリストがありません' : null,
      actions: [
        SheetAction(
          icon: Icons.playlist_add,
          label: '新しいプレイリストを作って追加',
          onTap: () => _addToNewPlaylist(item),
        ),
        for (final pl in playlists)
          SheetAction(
            icon: Icons.playlist_play,
            label: pl.name,
            subtitle: '${pl.itemIds.length} 曲',
            selected: pl.itemIds.contains(item.id),
            enabled: !pl.itemIds.contains(item.id),
            onTap: () {
              ref.read(playlistsProvider.notifier).addItems(pl.id, [item.id]);
              AppToast.instance.show(
                AppSnackBar.success('「${pl.name}」に追加しました'),
              );
            },
          ),
      ],
    );
  }

  Future<void> _addToNewPlaylist(LoopItem item) async {
    final name = await AppDialogs.prompt(context,
        title: '新しいプレイリスト',
        hintText: 'プレイリスト名',
        confirmLabel: '作成',
        maxLength: AppLimits.playlistNameMaxLength);
    if (name == null || !mounted) return;
    final pl = Playlist(id: IdGenerator.next(), name: name, itemIds: [item.id]);
    await ref.read(playlistsProvider.notifier).add(pl);
    if (!mounted) return;
    AppToast.instance.show(
      AppSnackBar.success('「$name」を作って追加しました'),
    );
  }

  Future<void> _deleteItem(LoopItem item) async {
    final confirmed = await AppDialogs.confirmDelete(context,
        message: '「${item.title}」を削除しますか？');
    if (confirmed && mounted) {
      ref.read(loopItemsProvider.notifier).delete(item.id);
      Navigator.of(context).pop();
    }
  }

  // --- オフライン保存 ---

  /// 保存シート（アプリ内に保存 / 端末に書き出し）。曲全体
  Future<void> _saveItem(LoopItem item) async {
    final choice = await SaveFlow.showSheet(context,
        title: item.title, offline: SaveFlow.canSaveOffline(item));
    if (choice == null || !mounted) return;
    await SaveFlow.run(context, ref, item: item, choice: choice);
  }

  Future<void> _clearOffline(LoopItem item) async {
    // 保存のピルと同じ場所にあるので、押し間違いで消えないよう確認する
    final ok = await AppDialogs.confirmDelete(context,
        title: 'オフラインデータを削除',
        message: '「${item.title}」のオフライン保存した動画と字幕を削除しますか？'
            '\n（曲の設定は残ります）');
    if (!ok || !mounted) return;
    await ref.read(loopItemsProvider.notifier).clearCache(item.id);
    if (mounted) {
      AppToast.instance.show(
        AppSnackBar.success('オフラインデータを削除しました'),
      );
    }
  }

  // --- YouTube URL ---

  String? _getYouTubeUrl(LoopItem item) {
    if (item.youtubeUrl != null && item.youtubeUrl!.isNotEmpty) {
      return item.youtubeUrl;
    }
    if (item.videoId != null) {
      return 'https://youtu.be/${item.videoId}';
    }
    return null;
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    AppToast.instance.show(
      AppSnackBar.success('URLをコピーしました'),
    );
  }

  void _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // --- タグ管理 ---

  void _showTagPicker(LoopItem item) => ItemTagSheet.show(context, ref, item);

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);
    final item = items.where((e) => e.id == widget.itemId).firstOrNull;

    if (item == null) {
      return const GlassScaffold(
        title: Text('詳細'),
        body: Center(child: Text('データが見つかりません')),
      );
    }

    _initControllers(item);
    final textTheme = Theme.of(context).textTheme;

    final ytUrl = _getYouTubeUrl(item);
    final itemTags = tags.where((t) => item.tagIds.contains(t.id)).toList();
    final regions = item.effectiveRegions;
    final thumbPath = item.thumbnailPath;
    final tone = thumbPath == null
        ? null
        : ref.watch(thumbToneProvider(thumbPath)).valueOrNull;

    // 横画面は AppBar を置かず、左の列の一番上に同じ行（戻る・保存・その他）
    final split = DetailSplit.of(MediaQuery.sizeOf(context));
    final actions = <Widget>[
      if (_hasChanges(item))
        TextButton.icon(
          onPressed: () => _save(item),
          icon: const Icon(Icons.save, size: AppIconSizes.sm),
          label: const Text('保存'),
        ),
      Builder(
        builder: (button) => IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: 'その他',
          onPressed: () => AppSheets.actions(
            context,
            anchor: button,
            actions: [
              SheetAction(
                icon: Icons.copy_outlined,
                label: '複製',
                onTap: () => _duplicateItem(item),
              ),
              SheetAction(
                icon: Icons.playlist_add,
                label: 'プレイリストに追加',
                onTap: () => _showAddToPlaylist(item),
              ),
              if (SaveFlow.canSave(item))
                SheetAction(
                  icon: Icons.download_outlined,
                  label: '保存・書き出し',
                  onTap: () => _saveItem(item),
                ),
              if (item.isCached)
                SheetAction(
                  icon: Icons.delete_sweep_outlined,
                  label: 'アプリ内の保存を削除',
                  onTap: () => _clearOffline(item),
                ),
              SheetAction(
                icon: Icons.delete_outline,
                label: '削除',
                destructive: true,
                onTap: () => _deleteItem(item),
              ),
            ],
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!_hasChanges(item)) {
          Navigator.of(context).pop();
          return;
        }
        if (await _confirmDiscard()) {
          if (!context.mounted) return;
          Navigator.of(context).pop();
        }
      },
      child: GlassScaffold(
        // ガラス風: 背景（サムネの色味）を AppBar の裏まで通す
        tone: tone,
        title: Text('詳細', style: textTheme.titleMedium),
        showAppBar: !split,
        actions: actions,
        // 本文の上端は bodyBuilder の context から（AppBar の高さが入る）
        bodyBuilder: (bodyContext) {
              final padding = MediaQuery.paddingOf(bodyContext);
              final viewPadding = MediaQuery.viewPaddingOf(bodyContext);
              final dim = Theme.of(context).colorScheme.onSurface;
              // サムネイル（横画面は左の列に大きく）
              final thumbnail = ClipRRect(
                borderRadius: AppRadius.borderXl,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ItemThumbnail(
                        item: item,
                        heroTag: 'thumb_${item.id}',
                        placeholder: ItemThumbnailPlaceholderLarge(item: item),
                      ),
                      if (item.thumbnailPath == null &&
                          ThumbnailQueueNotifier.canFetch(item))
                        Positioned(
                          right: AppSpacing.md,
                          bottom: AppSpacing.md,
                          child: GlassPill(
                            tooltip: 'サムネイルを取得',
                            padding: const EdgeInsets.all(_pillPadding),
                            onTap: _fetchingThumb
                                ? null
                                : () => _fetchThumbnail(item),
                            child: _fetchingThumb
                                ? const SizedBox.square(
                                    dimension: AppIconSizes.lg,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.image_search,
                                    size: AppIconSizes.lg),
                          ),
                        ),
                    ],
                  ),
                ),
              );
              // 再生 / 保存 / URL（サムネのすぐ下。縦も横も）。押しやすいように大きく、再生は幅いっぱい
              // （AB 区間は再生画面で登録する）
              final buttons = Row(
                children: [
                  Expanded(
                    child: GreenButton(
                      icon: Icons.play_arrow_rounded,
                      label: '再生',
                      size: _buttonSize,
                      onPressed: () => _openPlayer(item),
                    ),
                  ),
                  if (SaveFlow.canSave(item) || item.isCached) ...[
                  const SizedBox(width: AppSpacing.md),
                  GlassPill(
                    active: item.isCached,
                    tooltip: item.isCached
                        ? 'アプリ内に保存済み。タップで削除'
                        : '保存・書き出し',
                    padding: const EdgeInsets.all(_pillPadding),
                    onTap: () =>
                        item.isCached ? _clearOffline(item) : _saveItem(item),
                    child: Icon(
                      item.isCached ? Icons.offline_pin : Icons.download_outlined,
                      size: AppIconSizes.lg,
                      color: item.isCached ? AppTheme.accentGreen : null,
                    ),
                  ),
                  ],
                  if (ytUrl != null) ...[
                    const SizedBox(width: AppSpacing.md),
                    GlassPill(
                      tooltip: 'URL をコピー（長押しで開く）',
                      padding: const EdgeInsets.all(_pillPadding),
                      onTap: () => _copyUrl(ytUrl),
                      onLongPress: () => _openUrl(ytUrl),
                      child: const Icon(Icons.open_in_new, size: AppIconSizes.lg),
                    ),
                  ],
                ],
              );
              // 曲名・補足（縦はボタンの下、横は右の列の上）
              final info = <Widget>[
                  // 曲名（タップで編集）+ 補足
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: InkWell(
                      onTap: _editTitle,
                      borderRadius: AppRadius.borderMd,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _titleController.text,
                                    style: textTheme.titleLarge!.copyWith(fontSize: 18),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Icon(Icons.edit_outlined,
                                    size: AppIconSizes.s,
                                    color: dim.withValues(alpha: 0.4)),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(_subtitleText(item),
                                style: textTheme.labelSmall!
                                    .copyWith(color: dim.withValues(alpha: 0.7))),
                          ],
                        ),
                      ),
                    ),
                  ),
              ];
              // 右（横画面は右の列）: テンポとキー・タグ・区間・メモ
              final body = <Widget>[
                  // 再生できないと分かっている曲（年齢制限など）。通信の失敗のこともあるので試し直せる
                  if (item.isUnplayable) ...[
                    _buildUnplayableNotice(item),
                    const SizedBox(height: AppSpacing.lg),
                  ],

                  // テンポ / キー（未解析ならタップで解析、解析済みならタップで補正）と
                  // つなぎやすい曲を 1 行に
                  _buildMusicRow(item),
                  const SizedBox(height: AppSpacing.lg),

                  // タグ
                  GlassSurface(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('タグ', style: textTheme.titleSmall),
                        const SizedBox(height: AppSpacing.md),
                        _buildTagSection(item, itemTags),
                      ],
                    ),
                  ),

                  // AB 区間（登録は再生画面で。ここは名前・時間の手直し・書き出し・削除）。無ければ出さない
                  if (regions.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    _buildRegionsSection(item, regions),
                  ],

                  // メモ（ふだんは使わないので一番下に、面を敷かず小さく）
                  const SizedBox(height: AppSpacing.md),
                  _buildMemo(textTheme),
              ];
              if (split) {
                // 横: 左の列は戻るの行とサムネだけ（サムネを大きく）。曲名・ボタン・保存と
                // その他のメニューは右の列（メニューは右上）
                final size = MediaQuery.sizeOf(context);
                final thumbMaxHeight = size.height -
                    padding.top -
                    padding.bottom -
                    kMinInteractiveDimension -
                    AppSpacing.xs -
                    _thumbToButtons -
                    _buttonSize -
                    AppSpacing.xxl;
                final leftWidth = min(
                  size.width * _splitThumbMaxRatio,
                  thumbMaxHeight * 16 / 9 + AppSpacing.lg * 2 + viewPadding.left,
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: leftWidth,
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(
                            AppSpacing.lg + viewPadding.left,
                            padding.top,
                            AppSpacing.lg,
                            padding.bottom + AppSpacing.xxl),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                            child: Transform.translate(
                              // 戻るボタンの左端をサムネの左端に揃える
                              offset: const Offset(-AppSpacing.md, 0),
                              child: const DetailSplitTopBar(title: '詳細'),
                            ),
                          ),
                          thumbnail,
                          const SizedBox(height: _thumbToButtons),
                          buttons,
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(
                            AppSpacing.sm,
                            padding.top,
                            AppSpacing.lg + viewPadding.right,
                            padding.bottom + AppSpacing.xxl),
                        children: [
                          // 保存・その他のメニューは右の列の右上（左の戻るの行と同じ高さ）
                          SizedBox(
                            height: kMinInteractiveDimension,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: actions,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          ...info,
                          const SizedBox(height: AppSpacing.xl),
                          ...body,
                        ],
                      ),
                    ),
                  ],
                );
              }
              return ListView(
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg + viewPadding.left,
                    padding.top + AppSpacing.xs,
                    AppSpacing.lg + viewPadding.right,
                    padding.bottom + AppSpacing.xxl),
                children: [
                  thumbnail,
                  const SizedBox(height: _thumbToButtons),
                  buttons,
                  const SizedBox(height: AppSpacing.lg),
                  ...info,
                  const SizedBox(height: AppSpacing.xl),
                  ...body,
                ],
              );
        },
      ),
    );
  }

  /// 横画面の左の列（サムネ）の幅の上限（画面の幅に対して）。高さに収まる大きさ（下の
  /// ボタンの行の分を引く）がこれより小さければそちら
  static const _splitThumbMaxRatio = 0.55;

  /// サムネの下の再生などのボタンの高さ（押しやすいように大きく）と、サムネとの間
  static const _buttonSize = 52.0;
  static const _thumbToButtons = AppSpacing.md;

  /// 保存・URL の丸いボタンの余白（アイコン 24 + 余白 = 再生ボタンと同じ高さ）
  static const _pillPadding = (_buttonSize - AppIconSizes.lg) / 2;

  /// 曲名の下の補足: BPM・キー・再生回数・速度・出どころ
  String _subtitleText(LoopItem item) {
    final parts = <String>[
      ...item.musicInfoParts,
      '${item.playCount} 回再生',
      if (item.speed != 1.0) rateLabel(item.speed),
      if (item.isYouTube) 'YouTube' else 'ローカル',
    ];
    return parts.join('  ·  ');
  }

  Future<void> _editTitle() async {
    final name = await AppDialogs.prompt(context,
        title: 'タイトル',
        initialValue: _titleController.text,
        maxLength: AppLimits.titleMaxLength);
    if (name == null) return;
    setState(() => _titleController.text = name);
  }

  /// メモは空にもできるので AppDialogs.prompt（空 = キャンセル扱い）は使わない
  Future<void> _editMemo() async {
    final result = await AppDialogs.prompt(
      context,
      title: 'メモ',
      initialValue: _memoController.text,
      hintText: '練習メモなど',
      maxLength: AppLimits.memoMaxLength,
      maxLines: 4,
      minLines: 2,
      allowEmpty: true,
    );
    if (result == null || !mounted) return;
    setState(() => _memoController.text = result);
  }

  /// 区間の行のタップ・長押しから。行の脇（[anchor]）に出す
  void _showRegionEditMenu(LoopItem item, int index, {BuildContext? anchor}) {
    final region = item.effectiveRegions[index];
    AppSheets.actions(
      context,
      anchor: anchor,
      title: region.name,
      actions: [
        SheetAction(
          icon: Icons.edit,
          label: '名前を変更',
          onTap: () => _renameRegion(item, index),
        ),
        SheetAction(
          icon: Icons.timer,
          label: 'AB 時間を編集',
          subtitle: 'A ${TimeUtils.formatShortMs(region.pointAMs)}'
              '  B ${TimeUtils.formatShortMs(region.pointBMs)}',
          onTap: () => _editRegionTimes(item, index),
        ),
        if (SaveFlow.canSave(item))
          SheetAction(
            icon: Icons.file_download_outlined,
            label: '保存・書き出し',
            subtitle: 'この区間を音声 / 動画で端末に書き出す',
            onTap: () => _exportRegion(item, index),
          ),
        SheetAction(
          icon: Icons.delete_outline,
          label: '削除',
          destructive: true,
          onTap: () => _deleteRegion(item, index),
        ),
      ],
    );
  }

  /// 詳細ページから区間を書き出す。
  /// local はアイテムの元URI、YouTube は stream URL を解決してから書き出す。
  Future<void> _exportRegion(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    if (index >= regions.length) return;
    final region = regions[index];
    if (!region.hasA || !region.hasB) {
      AppToast.instance.show(
        AppSnackBar.info('A・B両方の地点を設定してください'),
      );
      return;
    }

    final choice = await SaveFlow.showSheet(
      context,
      title: '${region.name} を保存',
      rangeText: '${TimeUtils.formatShortMs(region.pointAMs)}'
          ' - ${TimeUtils.formatShortMs(region.pointBMs)}',
      offline: SaveFlow.canSaveOffline(item),
    );
    if (choice == null || !mounted) return;
    await SaveFlow.run(
      context,
      ref,
      item: item,
      choice: choice,
      startMs: region.pointAMs,
      endMs: region.pointBMs,
      exportTitle: choice.wholeTrack ? item.title : '${item.title}_${region.name}',
    );
  }

  void _renameRegion(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    final name = await AppDialogs.prompt(context,
        title: '区間名',
        initialValue: regions[index].name,
        hintText: '区間名を入力',
        maxLength: AppLimits.regionNameMaxLength);
    if (name == null) return;

    regions[index] = regions[index].copyWith(name: name);
    item.setRegions(regions);
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  void _editRegionTimes(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    final region = regions[index];
    // 検証付きのダイアログ（読めない値や A ≧ B は保存できない）
    final result = await showRegionTimeDialog(context,
        title: '${region.name} の AB 時間',
        aMs: region.pointAMs,
        bMs: region.pointBMs);
    if (result == null || !mounted) return;

    regions[index] = regions[index].copyWith(
      pointAMs: () => result.aMs,
      pointBMs: () => result.bMs,
    );
    item.setRegions(regions);
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  void _deleteRegion(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    if (index < 0 || index >= regions.length) return;
    final ok = await AppDialogs.confirmDelete(context,
        message: '区間「${regions[index].name}」を削除しますか？');
    if (!ok || !mounted) return;
    // 最後の 1 つも消せる（区間なし = 全体を再生。再生画面と同じ）
    regions.removeAt(index);
    item.setRegions(regions);
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  // --- タグセクション ---

  /// タグを外す。見えない長押しではなく × で外し、「元に戻す」を出す
  void _removeTag(LoopItem item, Tag tag) {
    ref.read(loopItemsProvider.notifier).removeTagFromItems([item.id], tag.id);
    AppToast.instance
      ..hide()
      ..show(AppSnackBar.action(
        'タグ「${tag.name}」を外しました',
        label: '元に戻す',
        onPressed: () => ref
            .read(loopItemsProvider.notifier)
            .addTagToItems([item.id], tag.id),
      ));
  }

  /// タグチップ（× で外す）と「+ 追加」
  Widget _buildTagSection(LoopItem item, List<Tag> itemTags) {
    final textTheme = Theme.of(context).textTheme;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...itemTags.map((t) => TagChip(
              tag: t,
              onDeleted: () => _removeTag(item, t),
            )),
        GlassPill(
          onTap: () => _showTagPicker(item),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md + 1, vertical: 3),
          child: Text(itemTags.isEmpty ? '+ タグを追加' : '+ 追加',
              style: textTheme.labelSmall),
        ),
      ],
    );
  }

  /// メモ: ふだんは使わないので、面を敷かずに小さな字で（空なら「メモ」とだけ）。タップで編集
  Widget _buildMemo(TextTheme textTheme) {
    final memo = _memoController.text;
    final color = AppTheme.muted(context, alpha: memo.isEmpty ? 0.4 : 0.6);
    return InkWell(
      onTap: _editMemo,
      borderRadius: AppRadius.borderMd,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.notes, size: AppIconSizes.s, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                memo.isEmpty ? 'メモ' : memo,
                style: (memo.isEmpty ? textTheme.labelSmall : textTheme.bodySmall)!
                    .copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// AB 区間の一覧（ガラス面）。行のタップでメニュー（名前・時間・書き出し・削除）。
  /// 区間の登録は再生画面で行う
  Widget _buildRegionsSection(LoopItem item, List<dynamic> regions) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return GlassSurface(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl, AppSpacing.lg, AppSpacing.md, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: [
                Text('AB 区間', style: textTheme.titleSmall),
                const SizedBox(width: AppSpacing.md),
                Text('${regions.length} 件', style: textTheme.labelSmall),
              ],
            ),
          ),
          // メニューは行の脇に出すので、行の context を取る
          for (var i = 0; i < regions.length; i++)
            Builder(builder: (row) => InkWell(
              onTap: () => _showRegionEditMenu(item, i, anchor: row),
              onLongPress: () => _showRegionEditMenu(item, i, anchor: row),
              borderRadius: AppRadius.borderSm,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
                child: Row(
                  children: [
                    Icon(Icons.repeat, size: AppIconSizes.s, color: dim),
                    const SizedBox(width: AppSpacing.md + 2),
                    Expanded(
                      child: Text(regions[i].name,
                          style: textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text(TimeUtils.formatShortMs(regions[i].pointAMs),
                        style: textTheme.labelSmall!
                            .copyWith(color: AppTheme.pointAColor)),
                    Text('  -  ', style: textTheme.labelSmall),
                    Text(TimeUtils.formatShortMs(regions[i].pointBMs),
                        style: textTheme.labelSmall!
                            .copyWith(color: AppTheme.pointBColor)),
                    if (regions[i].hasA && regions[i].hasB) ...[
                      const SizedBox(width: AppSpacing.md),
                      Text(
                        '${((regions[i].pointBMs - regions[i].pointAMs).abs() / 1000).toStringAsFixed(1)}s',
                        style: textTheme.labelSmall,
                      ),
                    ],
                  ],
                ),
              ),
            )),
        ],
      ),
    );
  }

  // --- Thumbnail ---

}

/// 詳細の「テンポ / キー」「つなぎやすい曲」の札（半分の幅に 2 つ並べる）。
/// アイコン + 値だけ。押せないときはアイコンも字も薄く
class _MusicTile extends StatelessWidget {
  const _MusicTile({required this.icon, required this.text, this.onTap});

  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final textTheme = Theme.of(context).textTheme;
    return GlassSurface(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
      child: Row(
        children: [
          Icon(icon,
              size: AppIconSizes.md,
              color: enabled ? AppTheme.accentGreen : AppTheme.muted(context, alpha: 0.3)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleSmall!.copyWith(
                  color: enabled ? null : AppTheme.muted(context, alpha: 0.4)),
            ),
          ),
        ],
      ),
    );
  }
}

// タグ編集シートは ItemTagSheet (widgets/item_tag_sheet.dart) に移動
