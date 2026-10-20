import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snack_bar.dart';
import '../core/utils/app_errors.dart';
import '../models/loop_item.dart';
import '../providers/data_provider.dart';
import 'cache_service.dart';
import 'export_runner.dart';
import 'export_service.dart';
import 'export_source.dart';
import 'youtube_service.dart';

/// 保存先: アプリ内（オフライン再生用）/ 端末へ書き出し（フォト・ミュージック）
enum SaveTarget {
  offline('アプリ内'),
  device('端末に書き出し');

  const SaveTarget(this.label);
  final String label;
}

/// 保存シートで決まったこと
class SaveChoice {
  const SaveChoice({
    required this.target,
    required this.audioOnly,
    required this.quality,
    required this.hqAudio,
    this.wholeTrack = false,
  });

  final SaveTarget target;
  final bool audioOnly;

  /// 動画の画質
  final ExportQuality quality;

  /// 音声のみで書き出すとき高音質の音声を使うか（false = 一体型の 96kbps）
  final bool hqAudio;

  /// 区間があっても曲全体を書き出す
  final bool wholeTrack;

  ExportChoice get exportChoice => ExportChoice(
    audioOnly ? ExportFormat.audioOnly : ExportFormat.mp4,
    quality: quality,
    hqAudio: hqAudio,
  );
}

/// 曲の保存の入口（曲詳細・単体再生・AB 設定・プレイリスト再生中・プレイリストの一括）。
/// 「アプリ内に保存」と「端末に書き出し」を 1 つのシートで選ぶ。
/// 以前は曲詳細がオフライン保存（動画だけ・画質は YouTube の一覧）、再生画面が書き出し
/// （音声/MP4・固定 4 段）で、入口も選べることも画面ごとに違っていた
class SaveFlow {
  SaveFlow._();

  /// 曲全体を書き出すときの終点（長さが分からない曲。ネイティブは末尾で止まる）
  static const _unknownEndMs = 24 * 60 * 60 * 1000;

  /// 保存シートを出す。キャンセルは null。
  /// [rangeText] があれば「区間 / 曲全体」を選べる（書き出しのとき）。
  /// [offline] が false ならアプリ内保存は選べない（ローカル動画など）
  static Future<SaveChoice?> showSheet(
    BuildContext context, {
    required String title,
    String? rangeText,
    bool offline = true,
  }) {
    return showModalBottomSheet<SaveChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SaveSheet(
        title: title,
        rangeText: rangeText,
        offlineAllowed: offline,
      ),
    );
  }

  /// アプリ内に保存できる曲か（YouTube だけ。ローカル動画はもう手元にある）
  static bool canSaveOffline(LoopItem item) =>
      item.isYouTube && item.videoId != null;

  /// 1 曲を保存する。[startMs]/[endMs] は書き出す範囲（null なら曲全体）。
  /// [playingUri] は再生中のソース（あればネット取得を省ける）
  static Future<void> run(
    BuildContext context,
    WidgetRef ref, {
    required LoopItem item,
    required SaveChoice choice,
    int? startMs,
    int? endMs,
    String? playingUri,
    String? exportTitle,
  }) async {
    if (choice.target == SaveTarget.offline) {
      await _runOffline(context, ref, item, choice);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final format = choice.exportChoice.format;
    String? input;
    try {
      input = await _inputFor(
        item,
        format,
        playingUri: playingUri,
        onStatus: (s) {
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(AppSnackBar.progress(s));
        },
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        AppSnackBar.error('動画の取得に失敗しました: ${AppErrors.describe(e)}'),
      );
      return;
    }
    messenger.hideCurrentSnackBar();
    if (input == null) {
      messenger.showSnackBar(AppSnackBar.info('書き出せる動画ソースがありません'));
      return;
    }
    if (!context.mounted) return;
    final whole = choice.wholeTrack || startMs == null || endMs == null;
    await runItemExportFlow(
      context,
      item: item,
      fallbackUri: input,
      startMs: whole ? 0 : startMs,
      endMs: whole ? (item.durationMs ?? _unknownEndMs) : endMs,
      choice: choice.exportChoice,
      title: exportTitle ?? item.title,
    );
  }

  /// 書き出しの元にするもの: オフライン保存 → ローカルの元ファイル → 再生中のソース → ネット
  static Future<String?> _inputFor(
    LoopItem item,
    ExportFormat format, {
    String? playingUri,
    void Function(String status)? onStatus,
  }) async {
    if (ExportSource.usesOffline(item, format)) {
      return CacheService.offlineVideoPath(item);
    }
    if (item.isLocal) return item.uri;
    // 再生中のソースが音声だけのオフライン保存なら MP4 には使えない
    if (playingUri != null &&
        playingUri.isNotEmpty &&
        playingUri != CacheService.offlineVideoPath(item)) {
      return playingUri;
    }
    final videoId = item.videoId;
    if (videoId == null) return null;
    onStatus?.call('動画を準備中...');
    final service = YouTubeService();
    try {
      return (await service.getVideoSource(videoId)).uri;
    } finally {
      service.dispose();
    }
  }

  /// アプリ内に保存（進捗ダイアログ・キャンセル可）
  static Future<void> _runOffline(
    BuildContext context,
    WidgetRef ref,
    LoopItem item,
    SaveChoice choice,
  ) async {
    if (!canSaveOffline(item)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(AppSnackBar.info('アプリ内に保存できるのは YouTube の曲だけです'));
      return;
    }
    final progress = _BulkProgress(total: 1)..label = item.title;
    final dialog = _showProgress(context, '保存中...', progress);
    final result = await _saveOffline(ref, item, choice, progress);
    if (progress.cancelled) {
      progress.dispose();
      return;
    }
    if (context.mounted) Navigator.of(context).pop();
    await dialog;
    progress.dispose();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (result.success) {
      final mb = (result.sizeBytes / 1024 / 1024).toStringAsFixed(1);
      final subMsg = result.subtitlePath != null ? '・字幕付き' : '';
      messenger.showSnackBar(
        AppSnackBar.success(
          'アプリ内に保存しました（${result.resolution ?? ''} ${mb}MB$subMsg）',
          duration: const Duration(seconds: 4),
        ),
      );
    } else if (!result.cancelled) {
      messenger.showSnackBar(AppSnackBar.error('保存失敗: ${result.error}'));
    }
  }

  /// 1 曲をアプリ内に保存して記録する（前に保存した別のファイルは消す）
  static Future<OfflineCacheResult> _saveOffline(
    WidgetRef ref,
    LoopItem item,
    SaveChoice choice,
    _BulkProgress progress,
  ) async {
    final cache = CacheService();
    final videoId = item.videoId!;
    final OfflineCacheResult result;
    if (choice.audioOnly) {
      progress.fraction = null;
      result = await cache.downloadAudioForOffline(
        item.id,
        videoId,
        isCancelled: () => progress.cancelled,
      );
    } else {
      progress.fraction = null;
      final CacheQuality? quality;
      try {
        quality = pickCacheQuality(
          await cache.qualityOptions(videoId),
          choice.quality.height,
        );
      } catch (e) {
        return OfflineCacheResult(
          error: '画質の取得に失敗しました: ${AppErrors.describe(e)}',
        );
      }
      if (quality == null) {
        return const OfflineCacheResult(error: '保存できる画質が見つかりません');
      }
      result = await cache.downloadForOffline(
        item.id,
        videoId,
        quality: quality,
        onProgress: (p) => progress.fraction = p,
        isCancelled: () => progress.cancelled,
      );
    }
    if (progress.cancelled) {
      // キャンセル直前に完走していたら孤児ファイルを掃除
      if (result.videoPath != null) {
        await cache.deletePaths(result.videoPath, result.subtitlePath);
      }
      return const OfflineCacheResult(cancelled: true);
    }
    if (!result.success) return result;
    final old = ref.read(loopItemsProvider.notifier).byId(item.id);
    await ref
        .read(loopItemsProvider.notifier)
        .saveCacheInfo(
          item.id,
          videoPath: result.videoPath!,
          subtitlePath: result.subtitlePath,
          resolution: result.resolution,
          sizeBytes: result.sizeBytes,
        );
    // 動画 → 音声だけなどで保存し直したとき、前のファイルが残らないように
    if (old?.cachedVideoPath case final p? when p != result.videoPath) {
      await cache.deletePaths(p, null);
    }
    return result;
  }

  /// YouTube にある画質から [height] 以下で最大のもの（無ければ一番小さいもの）
  static CacheQuality? pickCacheQuality(
    List<CacheQuality> options,
    int height,
  ) {
    int heightOf(CacheQuality q) =>
        int.tryParse(RegExp(r'^\d+').stringMatch(q.label) ?? '') ?? 0;
    final target = ExportSource.pickHeight(options.map(heightOf), height);
    if (target == null) return null;
    return options.firstWhere((q) => heightOf(q) == target);
  }

  /// プレイリストなど複数の曲をまとめて保存する（曲全体）。
  /// アプリ内に保存済みの曲と、アプリ内に保存できない曲（ローカル動画）は飛ばす
  static Future<void> runBulk(
    BuildContext context,
    WidgetRef ref, {
    required List<LoopItem> items,
    required SaveChoice choice,
  }) async {
    final targets = choice.target == SaveTarget.offline
        ? items.where((i) => canSaveOffline(i) && !i.isCached).toList()
        : items;
    final messenger = ScaffoldMessenger.of(context);
    if (targets.isEmpty) {
      messenger.showSnackBar(AppSnackBar.info('保存する曲がありません（すべて保存済み）'));
      return;
    }
    final progress = _BulkProgress(total: targets.length);
    final dialog = _showProgress(context, 'まとめて保存中...', progress);
    var done = 0;
    final failed = <String>[];
    for (final item in targets) {
      if (progress.cancelled) break;
      progress
        ..index = done
        ..label = item.title
        ..fraction = null;
      final ok = choice.target == SaveTarget.offline
          ? (await _saveOffline(ref, item, choice, progress)).success
          : await _exportQuietly(item, choice);
      if (progress.cancelled) break;
      if (ok) {
        done++;
      } else {
        failed.add(item.title);
      }
      progress.index = done + failed.length;
    }
    final cancelled = progress.cancelled;
    if (!cancelled && context.mounted) Navigator.of(context).pop();
    await dialog;
    progress.dispose();
    final head = cancelled ? 'やめました。' : '';
    final verb = choice.target == SaveTarget.offline ? '保存' : '書き出し';
    messenger.showSnackBar(
      failed.isEmpty
          ? AppSnackBar.success('$head$done 曲を$verbしました')
          : AppSnackBar.error(
              '$head$done 曲を$verbしました。失敗 ${failed.length} 曲: ${failed.take(3).join('、')}'
              '${failed.length > 3 ? ' ほか' : ''}',
            ),
    );
  }

  /// 1 曲を端末に書き出す（スナックバーを出さない。一括用）
  static Future<bool> _exportQuietly(LoopItem item, SaveChoice choice) async {
    final exportChoice = choice.exportChoice;
    try {
      final fallback = await _inputFor(item, exportChoice.format);
      if (fallback == null) return false;
      final input = await ExportSource.prepare(
        item,
        format: exportChoice.format,
        quality: exportChoice.quality,
        fallbackUri: fallback,
        hqAudio: exportChoice.hqAudio,
      );
      try {
        final result = await ExportService().exportRegion(
          inputUri: input.path,
          startMs: 0,
          endMs: item.durationMs ?? _unknownEndMs,
          format: exportChoice.format,
          title: item.title,
        );
        // Android 9 以前は端末に直接置けない（共有シート頼み）ので一括では失敗扱い
        return result.success && result.savedToGallery;
      } finally {
        await input.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  static Future<void> _showProgress(
    BuildContext context,
    String title,
    _BulkProgress progress,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      // 戻るキーで閉じない（閉じるのは保存の側。先に閉じると、その pop が下の画面を閉じてしまう）
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ListenableBuilder(
            listenable: progress,
            builder: (_, _) {
              final textTheme = Theme.of(ctx).textTheme;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (progress.total > 1)
                    Text(
                      '${progress.index + 1} / ${progress.total} 曲',
                      style: textTheme.labelMedium,
                    ),
                  Text(
                    progress.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  LinearProgressIndicator(value: progress.fraction),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                progress.cancel();
                Navigator.pop(ctx);
              },
              child: const Text('キャンセル'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 保存の進み具合（ダイアログが見る）
class _BulkProgress extends ChangeNotifier {
  _BulkProgress({required this.total});

  final int total;
  int _index = 0;
  String _label = '';
  double? _fraction;
  bool cancelled = false;

  int get index => _index;
  set index(int v) {
    _index = v.clamp(0, total - 1);
    notifyListeners();
  }

  String get label => _label;
  set label(String v) {
    _label = v;
    notifyListeners();
  }

  /// 0〜1。null は量が分からない（くるくる）
  double? get fraction => _fraction;
  set fraction(double? v) {
    _fraction = v;
    notifyListeners();
  }

  void cancel() => cancelled = true;
}

class _SaveSheet extends StatefulWidget {
  const _SaveSheet({
    required this.title,
    required this.rangeText,
    required this.offlineAllowed,
  });

  final String title;
  final String? rangeText;
  final bool offlineAllowed;

  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  // 前回の選び方を既定にする
  late SaveTarget _target = widget.offlineAllowed
      ? SaveTarget.values.firstWhere(
          (t) => t.name == AppBoxes.settings.get(SettingsKeys.saveTarget),
          orElse: () => SaveTarget.offline,
        )
      : SaveTarget.device;
  late bool _audioOnly =
      AppBoxes.settings.get(SettingsKeys.saveAudioOnly, defaultValue: false)
          as bool;
  late ExportQuality _quality = ExportQuality.fromName(
    AppBoxes.settings.get(SettingsKeys.exportQuality) as String?,
  );
  late bool _hqAudio =
      AppBoxes.settings.get(SettingsKeys.saveHqAudio, defaultValue: true)
          as bool;
  bool _wholeTrack = false;

  void _submit() {
    AppBoxes.settings
      ..put(SettingsKeys.saveTarget, _target.name)
      ..put(SettingsKeys.saveAudioOnly, _audioOnly)
      ..put(SettingsKeys.exportQuality, _quality.name)
      ..put(SettingsKeys.saveHqAudio, _hqAudio);
    Navigator.pop(
      context,
      SaveChoice(
        target: _target,
        audioOnly: _audioOnly,
        quality: _quality,
        hqAudio: _hqAudio,
        wholeTrack: _wholeTrack,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final offline = _target == SaveTarget.offline;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    Widget row(String label, Widget control) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(width: 64, child: Text(label, style: textTheme.labelMedium)),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: control),
          ),
        ],
      ),
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xl,
          0,
          AppSpacing.xl,
          bottomInset + AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleMedium,
            ),
            if (widget.rangeText != null && !offline)
              Text('区間 ${widget.rangeText}', style: textTheme.labelSmall),
            const SizedBox(height: AppSpacing.md),
            if (widget.offlineAllowed)
              row(
                '保存先',
                SegmentedButton<SaveTarget>(
                  showSelectedIcon: false,
                  segments: [
                    for (final t in SaveTarget.values)
                      ButtonSegment(value: t, label: Text(t.label)),
                  ],
                  selected: {_target},
                  onSelectionChanged: (s) => setState(() => _target = s.first),
                ),
              ),
            row(
              '種類',
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.audiotrack, size: AppIconSizes.s),
                    label: Text('音声のみ'),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.videocam, size: AppIconSizes.s),
                    label: Text('動画'),
                  ),
                ],
                selected: {_audioOnly},
                onSelectionChanged: (s) => setState(() => _audioOnly = s.first),
              ),
            ),
            if (!_audioOnly)
              row(
                '画質',
                DropdownButton<ExportQuality>(
                  value: _quality,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final q in ExportQuality.values)
                      DropdownMenuItem(value: q, child: Text(q.label)),
                  ],
                  onChanged: (q) => setState(() => _quality = q ?? _quality),
                ),
              ),
            // 動画の音声は 360p 超なら高音質、アプリ内の音声のみも高音質。選べるのは書き出しの音声のみだけ
            if (_audioOnly && !offline)
              row(
                '音質',
                DropdownButton<bool>(
                  value: _hqAudio,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: true, child: Text('高音質')),
                    DropdownMenuItem(
                      value: false,
                      child: Text('標準（96kbps・速い）'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _hqAudio = v ?? _hqAudio),
                ),
              ),
            if (widget.rangeText != null && !offline)
              row(
                '範囲',
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('区間')),
                    ButtonSegment(value: true, label: Text('曲全体')),
                  ],
                  selected: {_wholeTrack},
                  onSelectionChanged: (s) =>
                      setState(() => _wholeTrack = s.first),
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: Icon(
                  offline ? Icons.download_outlined : Icons.ios_share,
                  size: AppIconSizes.sm,
                ),
                label: Text(offline ? 'アプリ内に保存' : '書き出し'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
