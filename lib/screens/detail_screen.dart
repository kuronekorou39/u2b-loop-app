
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/audio/musical_key.dart';
import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/time_utils.dart';
import '../models/loop_item.dart';
import '../models/tag.dart';
import '../providers/data_provider.dart';
import '../providers/player_provider.dart';
import '../services/audio_analysis_service.dart';
import '../services/cache_service.dart';
import '../services/export_runner.dart';
import '../services/export_service.dart';
import '../services/youtube_service.dart';
import '../providers/thumb_tone_provider.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_panel.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/glass_surface.dart';
import '../widgets/item_tag_sheet.dart';
import '../widgets/item_thumbnail.dart';
import '../widgets/similar_tracks_sheet.dart';
import '../widgets/tag_chip.dart';
import '../widgets/tempo_key_sheet.dart';
import 'editor_screen.dart';
import 'player_screen.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/ui/app_dialogs.dart';

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

  Future<void> _openPlayer(LoopItem item) async {
    if (_hasChanges(item)) await _saveOnly(item);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(item: item)),
    );
  }

  /// 音声を取得してテンポ/キーを解析する（再生せずに単独で）
  Future<void> _analyze(LoopItem item) async {
    setState(() => _analyzing = true);
    final result = await AudioAnalysisService.analyzeItem(
      ref.read(loopItemsProvider.notifier),
      ref.read(youtubeServiceProvider),
      item,
    );
    if (!mounted) return;
    setState(() => _analyzing = false);
    final messenger = ScaffoldMessenger.of(context);
    if (result == null) {
      messenger.showSnackBar(AppSnackBar.error('テンポ/キーを解析できませんでした'));
    } else if (result.bpm == null && result.key == null) {
      messenger.showSnackBar(
          AppSnackBar.info('テンポ/キーを検出できませんでした。タップして手入力できます'));
    } else {
      messenger.showSnackBar(
          AppSnackBar.success('解析完了: ${_tempoKeyText(result.bpm, result.key)}'));
    }
  }

  String _tempoKeyText(double? bpm, String? key) {
    final parts = <String>[
      if (bpm != null) '${bpm.round()} BPM',
      if (key != null) MusicalKey.display(key)!,
    ];
    return parts.isEmpty ? '検出できず（タップで入力）' : parts.join(' · ');
  }

  Widget _buildTempoKeyLine(LoopItem item) {
    final unanalyzed =
        item.analyzedAt == null && item.bpm == null && item.musicalKey == null;
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    final analyzed = item.bpm != null || item.musicalKey != null;
    final label = _analyzing
        ? '解析中…'
        : unanalyzed
            ? 'タップして解析（BPM とキー）'
            : '${_tempoKeyText(item.bpm, item.musicalKey)}。タップで補正';
    Widget row({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback? onTap,
    }) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
          child: Row(
            children: [
              Icon(icon, size: AppIconSizes.md, color: AppTheme.accentGreen),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.titleSmall),
                    Text(subtitle, style: textTheme.labelSmall),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: dim),
            ],
          ),
        ),
      );
    }

    return GlassSurface(
      child: Column(
        children: [
          row(
            icon: Icons.speed,
            title: 'テンポ / キー',
            subtitle: label,
            onTap: _analyzing
                ? null
                : () => unanalyzed
                    ? _analyze(item)
                    : TempoKeySheet.show(context,
                        item: item, onReanalyze: () => _analyze(item)),
          ),
          // 解析済みなら、ライブラリからつなぎやすい曲を探せる
          if (analyzed) ...[
            Divider(
                height: 1,
                indent: 52,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06)),
            row(
              icon: Icons.join_inner,
              title: 'つなぎやすい曲',
              subtitle: 'テンポとキーが近い曲をライブラリから探す',
              onTap: () => _showSimilarTracks(item),
            ),
          ],
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

  Future<void> _openAbEditor(LoopItem item, {int regionIndex = 0}) async {
    if (_hasChanges(item)) await _saveOnly(item);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) =>
              EditorScreen(item: item, initialRegionIndex: regionIndex)),
    );
  }

  Future<void> _duplicateItem(LoopItem item) async {
    if (_hasChanges(item)) await _saveOnly(item);
    final copy =
        await ref.read(loopItemsProvider.notifier).duplicate(item);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success('複製しました'),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => DetailScreen(itemId: copy.id)),
      );
    }
  }

  void _showAddToPlaylist(LoopItem item) {
    final playlists = ref.read(playlistsProvider);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
              child: Text('プレイリストに追加',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('プレイリストがありません',
                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: Colors.grey)),
              ),
            for (final pl in playlists)
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: Text(pl.name),
                onTap: () {
                  Navigator.pop(ctx);
                  ref
                      .read(playlistsProvider.notifier)
                      .addItems(pl.id, [item.id]);
                  ScaffoldMessenger.of(context).showSnackBar(
                    AppSnackBar.success('「${pl.name}」に追加しました'),
                  );
                },
              ),
          ],
        ),
      ),
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

  /// 動画＋字幕をアプリ内にダウンロードし、オフライン再生可能にする。
  /// 画質を選んでから保存する（1080p等はネイティブで映像+音声を結合）。
  Future<void> _downloadOffline(LoopItem item) async {
    if (item.videoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.info('YouTube動画のみオフライン保存できます'),
      );
      return;
    }

    // 画質一覧を取得
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      AppSnackBar.progress('画質を取得中...'),
    );
    List<CacheQuality> options;
    try {
      options = await CacheService().qualityOptions(item.videoId!);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(AppSnackBar.error('画質の取得に失敗しました: $e'));
      return;
    }
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    if (options.isEmpty) {
      messenger.showSnackBar(
        AppSnackBar.info('保存できる画質が見つかりません'),
      );
      return;
    }

    // 画質選択
    final quality = await showDialog<CacheQuality>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('画質を選択'),
        children: [
          for (final q in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, q),
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    q.needsMerge ? Icons.high_quality : Icons.hd,
                    color: AppTheme.accentGreen),
                title: Text(q.label,
                    style: Theme.of(ctx).textTheme.bodyLarge),
                subtitle: Text(
                  [
                    q.sizeLabel,
                    if (q.needsMerge) '映像+音声を結合' else '音声込み',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
    if (quality == null || !mounted) return;

    final progress = ValueNotifier<double>(0);
    var cancelled = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('オフライン保存中...'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p > 0 ? p : null),
              const SizedBox(height: AppSpacing.md),
              Text('${(p * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(context);
            },
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );

    final result = await CacheService().downloadForOffline(
      item.id,
      item.videoId!,
      quality: quality,
      onProgress: (p) => progress.value = p,
      isCancelled: () => cancelled,
    );

    if (cancelled) {
      progress.dispose();
      // キャンセル直前に完走していたら孤児ファイルを掃除
      if (result.videoPath != null) {
        await CacheService()
            .deletePaths(result.videoPath, result.subtitlePath);
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(); // 進捗ダイアログを閉じる
    progress.dispose();
    if (!mounted) return;

    if (result.success) {
      await ref.read(loopItemsProvider.notifier).saveCacheInfo(
            item.id,
            videoPath: result.videoPath!,
            subtitlePath: result.subtitlePath,
            resolution: result.resolution,
            sizeBytes: result.sizeBytes,
          );
      if (!mounted) return;
      final mb = (result.sizeBytes / 1024 / 1024).toStringAsFixed(1);
      final subMsg = result.subtitlePath != null ? '・字幕付き' : '（字幕なし）';
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.success(
            'オフライン保存しました（${result.resolution ?? ''} ${mb}MB$subMsg）',
            duration: const Duration(seconds: 4)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.error('保存失敗: ${result.error}'),
      );
    }
  }

  Future<void> _clearOffline(LoopItem item) async {
    await ref.read(loopItemsProvider.notifier).clearCache(item.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
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
    ScaffoldMessenger.of(context).showSnackBar(
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

  void _showTagPicker(LoopItem item) {
    final tags = ref.read(tagsProvider);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => ItemTagSheet(
        tags: tags,
        item: item,
        onToggle: (tagId, add) async {
          if (add) {
            await ref
                .read(loopItemsProvider.notifier)
                .addTagToItems([item.id], tagId);
          } else {
            await ref
                .read(loopItemsProvider.notifier)
                .removeTagFromItems([item.id], tagId);
          }
        },
        onCreateAndAdd: (name) async {
          final tag = await ref.read(tagsProvider.notifier).create(name);
          await ref
              .read(loopItemsProvider.notifier)
              .addTagToItems([item.id], tag.id);
          return tag;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(loopItemsProvider);
    final tags = ref.watch(tagsProvider);
    final item = items.where((e) => e.id == widget.itemId).firstOrNull;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('詳細')),
        body: const Center(child: Text('データが見つかりません')),
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
      child: Scaffold(
        // ガラス風: 背景（サムネの色味）を AppBar の裏まで通す
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text('詳細', style: textTheme.titleMedium),
          actions: [
            if (_hasChanges(item))
              TextButton.icon(
                onPressed: () => _save(item),
                icon: const Icon(Icons.save, size: AppIconSizes.sm),
                label: const Text('保存'),
              ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'duplicate') _duplicateItem(item);
                if (v == 'playlist') _showAddToPlaylist(item);
                if (v == 'offline_save') _downloadOffline(item);
                if (v == 'offline_delete') _clearOffline(item);
                if (v == 'delete') _deleteItem(item);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'duplicate', child: Text('複製')),
                const PopupMenuItem(
                    value: 'playlist', child: Text('プレイリストに追加')),
                if (item.isYouTube && item.videoId != null)
                  PopupMenuItem(
                    value: item.isCached ? 'offline_delete' : 'offline_save',
                    child: Text(item.isCached
                        ? 'オフラインデータを削除'
                        : 'オフライン保存（字幕付き）'),
                  ),
                const PopupMenuItem(
                    value: 'delete',
                    child:
                        Text('削除', style: TextStyle(color: Colors.red))),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(child: AppBackdrop(tone: tone)),
            Builder(builder: (bodyContext) {
              final padding = MediaQuery.paddingOf(bodyContext);
              final viewPadding = MediaQuery.viewPaddingOf(bodyContext);
              final dim = Theme.of(context).colorScheme.onSurface;
              return ListView(
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg + viewPadding.left,
                    padding.top + AppSpacing.xs,
                    AppSpacing.lg + viewPadding.right,
                    padding.bottom + AppSpacing.xxl),
                children: [
                  // サムネイル
                  ClipRRect(
                    borderRadius: AppRadius.borderXl,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ItemThumbnail(
                        item: item,
                        heroTag: 'thumb_${item.id}',
                        placeholder: ItemThumbnailPlaceholderLarge(item: item),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg + 2),

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
                  const SizedBox(height: AppSpacing.lg),

                  // 再生 / AB 設定 / オフライン / URL
                  Row(
                    children: [
                      GreenButton(
                        icon: Icons.play_arrow_rounded,
                        label: '再生',
                        onPressed: () => _openPlayer(item),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      GlassPill(
                        onTap: () => _openAbEditor(item),
                        tooltip: 'AB 区間を設定',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.tune, size: AppIconSizes.sm),
                            const SizedBox(width: AppSpacing.sm),
                            Text('AB 設定', style: textTheme.labelMedium),
                          ],
                        ),
                      ),
                      if (item.isYouTube && item.videoId != null) ...[
                        const SizedBox(width: AppSpacing.md),
                        GlassPill(
                          active: item.isCached,
                          tooltip: item.isCached
                              ? 'オフライン保存済み。タップで削除'
                              : 'オフライン保存（字幕付き）',
                          padding: const EdgeInsets.all(10),
                          onTap: () => item.isCached
                              ? _clearOffline(item)
                              : _downloadOffline(item),
                          child: Icon(
                            item.isCached ? Icons.offline_pin : Icons.download_outlined,
                            size: AppIconSizes.md,
                            color: item.isCached ? AppTheme.accentGreen : null,
                          ),
                        ),
                      ],
                      if (ytUrl != null) ...[
                        const SizedBox(width: AppSpacing.md),
                        GlassPill(
                          tooltip: 'URL をコピー（長押しで開く）',
                          padding: const EdgeInsets.all(10),
                          onTap: () => _copyUrl(ytUrl),
                          onLongPress: () => _openUrl(ytUrl),
                          child: const Icon(Icons.open_in_new, size: AppIconSizes.md),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),

                  // AB 区間
                  _buildRegionsSection(item, regions),
                  const SizedBox(height: AppSpacing.lg),

                  // テンポ / キー（未解析ならタップで解析、解析済みならタップで補正）
                  _buildTempoKeyLine(item),
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
                  const SizedBox(height: AppSpacing.lg),

                  // メモ（タップで編集）
                  GlassSurface(
                    onTap: _editMemo,
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('メモ', style: textTheme.titleSmall),
                            const Spacer(),
                            Icon(Icons.edit_outlined,
                                size: AppIconSizes.s,
                                color: dim.withValues(alpha: 0.4)),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          _memoController.text.isEmpty
                              ? '練習メモなど'
                              : _memoController.text,
                          style: textTheme.bodyMedium!.copyWith(
                            color: dim.withValues(
                                alpha: _memoController.text.isEmpty ? 0.4 : 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 曲名の下の補足: BPM・キー・再生回数・速度・出どころ
  String _subtitleText(LoopItem item) {
    final parts = <String>[
      if (item.bpm != null) 'BPM ${item.bpm!.round()}',
      if (item.musicalKey != null) item.musicalKey!,
      '${item.playCount} 回再生',
      if (item.speed != 1.0) '${item.speed}x',
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
    final controller = TextEditingController(text: _memoController.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('メモ'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AppLimits.memoMaxLength,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(
            hintText: '練習メモなど',
            isDense: true,
            border: OutlineInputBorder(),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    setState(() => _memoController.text = result);
  }

  void _showRegionEditMenu(LoopItem item, int index) {
    final region = item.effectiveRegions[index];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('名前を変更'),
              onTap: () {
                Navigator.pop(ctx);
                _renameRegion(item, index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer),
              title: Text(
                'A: ${region.hasA ? TimeUtils.formatShort(Duration(milliseconds: region.pointAMs!)) : "--:--"}'
                '  B: ${region.hasB ? TimeUtils.formatShort(Duration(milliseconds: region.pointBMs!)) : "--:--"}',
              ),
              subtitle: const Text('AB時間を編集'),
              onTap: () {
                Navigator.pop(ctx);
                _editRegionTimes(item, index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('書き出し'),
              subtitle: const Text('この区間をMP4/音声で保存'),
              onTap: () {
                Navigator.pop(ctx);
                _exportRegion(item, index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('削除',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteRegion(item, index);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 詳細ページから区間を書き出す。
  /// local はアイテムの元URI、YouTube は stream URL を解決してから書き出す。
  Future<void> _exportRegion(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    if (index >= regions.length) return;
    final region = regions[index];
    if (!region.hasA || !region.hasB) {
      ScaffoldMessenger.of(context).showSnackBar(
        AppSnackBar.info('A・B両方の地点を設定してください'),
      );
      return;
    }

    // 形式選択
    final format = await showDialog<ExportFormat>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${region.name} を書き出し'),
        content: Text(
          '${TimeUtils.formatShort(Duration(milliseconds: region.pointAMs!))}'
          ' - ${TimeUtils.formatShort(Duration(milliseconds: region.pointBMs!))}',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(ctx, ExportFormat.audioOnly),
            icon: const Icon(Icons.audiotrack, size: AppIconSizes.s),
            label: const Text('音声のみ'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(ctx, ExportFormat.mp4),
            icon: const Icon(Icons.videocam, size: AppIconSizes.s),
            label: const Text('MP4'),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;

    // 入力URI解決（local=元URI、YouTube=stream URL を都度解決）
    String? inputUri;
    if (item.isLocal) {
      inputUri = item.uri;
    } else if (item.videoId != null) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        AppSnackBar.progress('動画を準備中...'),
      );
      final service = YouTubeService();
      try {
        final source = await service.getVideoSource(item.videoId!);
        inputUri = source.uri;
      } catch (e) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          AppSnackBar.error('動画の取得に失敗しました: $e'),
        );
        return;
      } finally {
        service.dispose();
      }
      messenger.hideCurrentSnackBar();
    }

    if (inputUri == null || inputUri.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          AppSnackBar.info('書き出せる動画ソースがありません'),
        );
      }
      return;
    }

    if (!mounted) return;
    await runExportFlow(
      context,
      inputUri: inputUri,
      startMs: region.pointAMs!,
      endMs: region.pointBMs!,
      format: format,
      title: '${item.title}_${region.name}',
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
    item.regions = List.from(regions);
    if (regions.isNotEmpty) {
      item.pointAMs = regions.first.pointAMs ?? 0;
      item.pointBMs = regions.first.pointBMs ?? 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  void _editRegionTimes(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    final region = regions[index];
    final aController = TextEditingController(
        text: region.hasA ? (region.pointAMs! / 1000).toStringAsFixed(1) : '');
    final bController = TextEditingController(
        text: region.hasB ? (region.pointBMs! / 1000).toStringAsFixed(1) : '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${region.name} のAB時間'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aController,
              decoration: const InputDecoration(
                labelText: 'A (秒)',
                hintText: '例: 10.5',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bController,
              decoration: const InputDecoration(
                labelText: 'B (秒)',
                hintText: '例: 45.0',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // dispose後のcontrollerから .text を読むのはAPI契約違反なので先に取り出す
    final aText = aController.text.trim();
    final bText = bController.text.trim();
    aController.dispose();
    bController.dispose();
    if (result != true) return;

    final aParsed = aText.isNotEmpty ? double.tryParse(aText) : null;
    final bParsed = bText.isNotEmpty ? double.tryParse(bText) : null;
    final aMs = aParsed != null ? (aParsed * 1000).round() : null;
    final bMs = bParsed != null ? (bParsed * 1000).round() : null;

    regions[index] = regions[index].copyWith(
      pointAMs: () => aMs,
      pointBMs: () => bMs,
    );
    item.regions = List.from(regions);
    if (regions.isNotEmpty) {
      item.pointAMs = regions.first.pointAMs ?? 0;
      item.pointBMs = regions.first.pointBMs ?? 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  void _deleteRegion(LoopItem item, int index) async {
    final regions = item.effectiveRegions;
    regions.removeAt(index);
    item.regions = List.from(regions);
    if (regions.isNotEmpty) {
      item.pointAMs = regions.first.pointAMs ?? 0;
      item.pointBMs = regions.first.pointBMs ?? 0;
    } else {
      item.pointAMs = 0;
      item.pointBMs = 0;
    }
    await ref.read(loopItemsProvider.notifier).update(item);
    if (mounted) setState(() {});
  }

  // --- タグセクション ---

  /// タグチップ（長押しで外す）と「+ 追加」
  Widget _buildTagSection(LoopItem item, List<Tag> itemTags) {
    final textTheme = Theme.of(context).textTheme;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...itemTags.map((t) => GestureDetector(
              onLongPress: () {
                ref
                    .read(loopItemsProvider.notifier)
                    .removeTagFromItems([item.id], t.id);
              },
              child: TagChip(tag: t),
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

  /// AB 区間の一覧（ガラス面）。行のタップでメニュー（名前・時間・書き出し・削除）、
  /// 見出しの「編集」で AB 設定画面へ
  Widget _buildRegionsSection(LoopItem item, List<dynamic> regions) {
    final textTheme = Theme.of(context).textTheme;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return GlassSurface(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl, AppSpacing.md, AppSpacing.md, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('AB 区間', style: textTheme.titleSmall),
              const SizedBox(width: AppSpacing.md),
              Text(regions.isEmpty ? '未設定' : '${regions.length} 件',
                  style: textTheme.labelSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _openAbEditor(item),
                icon: Icon(regions.isEmpty ? Icons.add : Icons.edit_outlined,
                    size: AppIconSizes.s),
                label: Text(regions.isEmpty ? '設定' : '編集'),
              ),
            ],
          ),
          for (var i = 0; i < regions.length; i++)
            InkWell(
              onTap: () => _showRegionEditMenu(item, i),
              onLongPress: () => _showRegionEditMenu(item, i),
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
            ),
        ],
      ),
    );
  }

  // --- Thumbnail ---

}

// タグ編集シートは ItemTagSheet (widgets/item_tag_sheet.dart) に移動
