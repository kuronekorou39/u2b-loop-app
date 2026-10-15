import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../core/utils/add_input.dart';
import '../../core/utils/app_errors.dart';
import '../../providers/data_provider.dart';
import '../../services/playlist_service.dart';
import '../../services/share_service.dart';
import '../../widgets/share_import_dialog.dart';
import 'playlist_video_select_page.dart';

/// ホームの「追加」から始まる取り込みの流れ。
///
/// URL の判定（[AddInput]）→ 動画 1 本 / プレイリスト全体 / 共有 URL / ローカルファイル。
/// プレイリストは進捗ダイアログ（キャンセル可）→ 重複の確認 → タグ付与 → 一括追加。
/// 画面の状態は持たないので、呼ぶたびに作って使い捨てる
class YouTubeImportFlow {
  YouTubeImportFlow({required this.context, required this.ref});

  final BuildContext context;
  final WidgetRef ref;

  bool _importCancelled = false;

  bool get _mounted => context.mounted;

  void _snack(SnackBar bar) {
    if (_mounted) ScaffoldMessenger.of(context).showSnackBar(bar);
  }

  // --- 追加ダイアログ ---

  void showAddDialog() {
    final urlController = TextEditingController();

    Future<void> doAdd(BuildContext dialogCtx) async {
      final input = AddInput.parse(urlController.text);
      switch (input) {
        case AddInputEmpty():
          return;
        case AddInputShare(:final url):
          Navigator.pop(dialogCtx);
          final data = ShareService.decode(url);
          if (data != null && _mounted) {
            showShareImportDialog(context, ref, data);
          } else {
            _snack(AppSnackBar.info('無効な共有URLです'));
          }
        case AddInputPlaylist(:final playlistId):
          Navigator.pop(dialogCtx);
          importPlaylist(playlistId);
        case AddInputVideoInPlaylist(:final videoId, :final playlistId, :final url):
          Navigator.pop(dialogCtx);
          final choice = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('どちらを追加しますか？',
                  style: Theme.of(ctx).textTheme.titleMedium),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'video'),
                  child: const Text('この動画のみ'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'playlist'),
                  child: const Text('プレイリスト全体'),
                ),
              ],
            ),
          );
          if (!_mounted || choice == null) return;
          if (choice == 'playlist') {
            importPlaylist(playlistId);
          } else {
            _addVideo(videoId, url);
          }
        case AddInputVideo(:final videoId, :final url):
          Navigator.pop(dialogCtx);
          _addVideo(videoId, url);
        case AddInputInvalid():
          _snack(AppSnackBar.info('無効なYouTube URLです'));
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('追加', style: Theme.of(ctx).textTheme.displaySmall),
        // 横画面でキーボードが出ても溢れないように
        scrollable: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
        ],
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              autofocus: true,
              maxLength: AppLimits.urlMaxLength,
              decoration: const InputDecoration(
                hintText: 'YouTube URL / 共有URL',
                prefixIcon: Icon(Icons.link, size: AppIconSizes.sm),
                isDense: true,
                border: OutlineInputBorder(),
                counterText: '',
              ),
              style: Theme.of(ctx).textTheme.bodyMedium,
              maxLines: 3,
              minLines: 3,
              onSubmitted: (_) => doAdd(ctx),
            ),
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                onPressed: () => doAdd(ctx),
                icon: const Icon(Icons.play_circle_fill),
                iconSize: 40,
                color: Theme.of(ctx).colorScheme.primary,
                tooltip: '追加',
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Text('または',
                      style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                          color: AppTheme.muted(ctx, alpha: 0.4))),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  addLocalFile();
                },
                icon: const Icon(Icons.folder_open, size: AppIconSizes.sm),
                label: const Text('ローカルファイルを選択'),
              ),
            ),
          ],
        ),
      ),
    ).then((_) {
      // ダイアログのアニメーション完了後にdispose
      Future.delayed(const Duration(milliseconds: 300), urlController.dispose);
    });
  }

  void _addVideo(String videoId, String url) {
    ref.read(loopItemsProvider.notifier).addYouTubeAndFetch(videoId, url);
    _snack(AppSnackBar.success('追加しました（情報を取得中...）'));
  }

  // --- ローカルファイル ---

  Future<void> addLocalFile() async {
    // file_picker はAndroidで選択ファイルをキャッシュへコピーしてから返すため、
    // 大きい動画だとコピー完了まで待たされる。その間ローディングを表示する。
    var loadingShown = false;
    void showCopyLoading() {
      if (loadingShown || !_mounted) return;
      loadingShown = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: AppIconSizes.md,
                      height: AppIconSizes.md,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: AppSpacing.xl),
                    Text('ファイルを読み込み中...'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    void hideCopyLoading() {
      if (loadingShown && _mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      loadingShown = false;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
        onFileLoading: (status) {
          if (status == FilePickerStatus.picking) {
            showCopyLoading();
          } else {
            hideCopyLoading();
          }
        },
      );
    } finally {
      hideCopyLoading();
    }
    if (result == null || result.files.isEmpty) return;

    // path（ファイルパス）またはidentifier（content:// URI）を使用
    final files = <({String path, String name})>[];
    for (final f in result.files) {
      final uri = f.path ?? f.identifier;
      if (uri == null || uri.isEmpty) continue;
      files.add((path: uri, name: f.name));
    }
    if (files.isEmpty) return;

    final count = ref.read(loopItemsProvider.notifier).addLocalFilesSync(files);
    if (count > 0) {
      _snack(AppSnackBar.success('$count件追加しました（サムネイル取得中...）'));
    }
  }

  // --- YouTubeプレイリストインポート ---

  Future<void> importPlaylist(String playlistId) async {
    if (!_mounted) return;
    _importCancelled = false;

    // 進捗付きダイアログ（キャンセル可能）
    final countNotifier = ValueNotifier<int>(0);
    final statusNotifier = ValueNotifier<String>('プレイリスト情報を取得中...');
    // 進捗ダイアログを閉じたあとに例外が起きると、catch節のpopが
    // 一覧画面自体をpopしてしまうため、閉じたかどうかを覚えておく
    var progressDialogOpen = true;
    void closeProgressDialog() {
      if (!progressDialogOpen) return;
      progressDialogOpen = false;
      if (_mounted) Navigator.pop(context);
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: ValueListenableBuilder<String>(
          valueListenable: statusNotifier,
          builder: (_, status, _) => ValueListenableBuilder<int>(
            valueListenable: countNotifier,
            builder: (_, count, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: AppIconSizes.lg,
                      height: AppIconSizes.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: AppSpacing.xl),
                    Expanded(
                        child: Text(status,
                            style: Theme.of(ctx).textTheme.bodyLarge)),
                  ],
                ),
                if (count > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: Text('$count 件取得済み',
                        style: Theme.of(ctx).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _importCancelled = true;
              closeProgressDialog();
            },
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );

    try {
      try {
        statusNotifier.value = 'プレイリスト情報を取得中...';
        final data = await PlaylistService().fetch(
          playlistId,
          isCancelled: () => _importCancelled,
          onProgress: (count) {
            countNotifier.value = count;
            if (count > 0) statusNotifier.value = '動画を取得中...';
          },
        );
        if (_importCancelled || !_mounted) return;
        closeProgressDialog();

        final videos = data.videos;
        if (videos.isEmpty) {
          _snack(AppSnackBar.info(playlistId.startsWith('RD')
              ? 'ミックスリストの取得に失敗しました（YouTube側の制限の可能性）'
              : 'プレイリストに動画がありません'));
          return;
        }

        final playlistTitle = data.title.isNotEmpty ? data.title : 'プレイリスト';

        // 既存アイテムとの重複チェック
        final existingVideoIds = ref
            .read(loopItemsProvider)
            .map((i) => i.videoId)
            .whereType<String>()
            .toSet();
        final duplicates =
            videos.where((v) => existingVideoIds.contains(v.id)).toList();
        final newVideos =
            videos.where((v) => !existingVideoIds.contains(v.id)).toList();

        if (duplicates.isEmpty) {
          _addVideos(videos, playlistTitle);
        } else {
          await _showDuplicateDialog(
            playlistTitle: playlistTitle,
            allVideos: videos,
            newVideos: newVideos,
            duplicates: duplicates,
          );
        }
      } finally {
        countNotifier.dispose();
        statusNotifier.dispose();
      }
    } catch (e) {
      if (_importCancelled) return;
      closeProgressDialog();
      _snack(AppSnackBar.error('取得に失敗しました: ${AppErrors.describe(e)}'));
    }
  }

  Future<void> _addVideos(
      List<PlaylistVideoInfo> videos, String playlistTitle) async {
    // タグを選択/作成するダイアログ
    final tagId = await _showImportTagDialog(playlistTitle);
    if (!_mounted) return;

    // 即座にHive保存（サムネイルDLなし）→ UIに即反映
    final notifier = ref.read(loopItemsProvider.notifier);
    final addedIds = await notifier.addYouTubeBatch(
      videos: videos
          .map((v) => (
                videoId: v.id,
                title: v.title,
                url: 'https://youtu.be/${v.id}',
                thumbnailUrl: v.thumbnailHighUrl,
              ))
          .toList(),
      tagId: tagId,
    );

    _snack(AppSnackBar.success(
        '「$playlistTitle」から${addedIds.length}曲を追加しました'));

    // サムネイルをバックグラウンドでダウンロード
    if (addedIds.isNotEmpty) {
      notifier.downloadThumbnailsInBackground(addedIds);
    }
  }

  /// インポート時にタグを付与するか選択するダイアログ
  Future<String?> _showImportTagDialog(String playlistTitle) async {
    final tags = ref.read(tagsProvider);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final textTheme = Theme.of(ctx).textTheme;
        return AlertDialog(
          title: Text('タグを付与', style: textTheme.titleMedium),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('追加する曲に共通のタグを付けますか？',
                  style: textTheme.bodyMedium
                      ?.copyWith(color: AppTheme.muted(ctx))),
              const SizedBox(height: AppSpacing.lg),
              // 既存タグ
              if (tags.isNotEmpty)
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final tag in tags)
                      ActionChip(
                        label: Text(tag.name, style: textTheme.labelMedium),
                        onPressed: () => Navigator.pop(ctx, tag.id),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                  ],
                ),
              const SizedBox(height: AppSpacing.md),
              // プレイリスト名で新規作成
              OutlinedButton.icon(
                onPressed: () async {
                  final tag =
                      await ref.read(tagsProvider.notifier).create(playlistTitle);
                  if (ctx.mounted) Navigator.pop(ctx, tag.id);
                },
                icon: const Icon(Icons.add, size: AppIconSizes.s),
                label: Text('「$playlistTitle」タグを作成',
                    style: textTheme.labelMedium),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Theme.of(ctx).dividerColor),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('スキップ'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDuplicateDialog({
    required String playlistTitle,
    required List<PlaylistVideoInfo> allVideos,
    required List<PlaylistVideoInfo> newVideos,
    required List<PlaylistVideoInfo> duplicates,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final textTheme = Theme.of(ctx).textTheme;
        return AlertDialog(
          title: Text('$playlistTitle (${allVideos.length}件)',
              style: textTheme.titleMedium),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${duplicates.length}件が既に登録されています。',
                  style: textTheme.bodyMedium),
              if (newVideos.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text('新規: ${newVideos.length}件',
                      style: textTheme.bodySmall),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('キャンセル'),
            ),
            if (newVideos.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'skip'),
                child: Text('新規のみ追加 (${newVideos.length}件)'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: Text('すべて追加 (${allVideos.length}件)'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'select'),
              child: const Text('個別に選択'),
            ),
          ],
        );
      },
    );
    // lint が getter 越しの mounted を見ないので、ここは直接 context.mounted
    if (!context.mounted || result == null || result == 'cancel') return;

    switch (result) {
      case 'skip':
        _addVideos(newVideos, playlistTitle);
      case 'all':
        _addVideos(allVideos, playlistTitle);
      case 'select':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlaylistVideoSelectPage(
              videos: allVideos,
              duplicateIds: duplicates.map((v) => v.id).toSet(),
              playlistTitle: playlistTitle,
              onConfirm: (selected) => _addVideos(selected, playlistTitle),
            ),
          ),
        );
    }
  }
}
