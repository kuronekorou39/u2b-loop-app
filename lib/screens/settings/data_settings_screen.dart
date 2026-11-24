import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_boxes.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../core/utils/app_errors.dart';
import '../../providers/bulk_analysis_provider.dart';
import '../../providers/data_provider.dart';
import '../../providers/thumbnail_queue_provider.dart';
import '../../services/backup_service.dart';
import '../../services/cache_service.dart';
import '../../services/local_media_import.dart';
import '../../services/playback/media_cache.dart';
import '../../services/waveform_cache.dart';
import '../../widgets/settings/backup_export_dialog.dart';
import '../../widgets/settings/settings_parts.dart';
import '../../widgets/thumbnail_queue_bar.dart';

/// 設定「データ」: バックアップ（曲・プレイリスト・タグ・AB 区間を 1 つのファイルに書き出す / 復元）と、
/// 端末に残しているもの（オフライン動画・自動キャッシュ・保存済みの波形）とその削除。
/// 行には今の値だけを出し、説明は確かめるダイアログに書く。消すものは右端のごみ箱
class DataSettingsScreen extends ConsumerStatefulWidget {
  const DataSettingsScreen({super.key});

  /// ページの名前（トップのボタンと同じ）
  static const title = 'データ';

  /// オフライン動画の保存先（true=端末に残す[documents] / false=一時領域[cache]）
  static bool get keepOfflineVideos =>
      AppBoxes.settings.get(SettingsKeys.cacheToDocuments, defaultValue: true)
          as bool;

  @override
  ConsumerState<DataSettingsScreen> createState() => _DataSettingsScreenState();
}

class _DataSettingsScreenState extends ConsumerState<DataSettingsScreen> {
  bool _busy = false;

  /// サムネイルの無い曲の数（列が空になったら数え直す）
  Future<int>? _missingThumbs;

  void _toast(AppToastMessage bar) {
    if (mounted) AppToast.instance.show(bar);
  }

  /// 裏の取得・解析が動いている間は、一覧を丸ごと置き換える操作をしない
  bool get _replaceLocked =>
      (ref.read(thumbnailQueueProvider)?.running ?? false) ||
      ref.read(bulkAnalysisProvider) != null;

  // ─── バックアップ ───

  Future<void> _exportData() async {
    if (!await BackupExportDialog.show(context) || !mounted) return;
    setState(() => _busy = true);
    try {
      final json = BackupService.encode(
        items: AppBoxes.loopItems.values.toList(),
        playlists: AppBoxes.playlists.values.toList(),
        tags: AppBoxes.tags.values.toList(),
      );
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'バックアップを保存',
        fileName: BackupService.fileName(),
        bytes: Uint8List.fromList(utf8.encode(json)),
      );
      if (saved != null) _toast(AppSnackBar.success('書き出しました'));
    } catch (e) {
      _toast(AppSnackBar.error('書き出しに失敗しました: ${AppErrors.describe(e)}'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importData() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final bytes = picked?.files.single.bytes;
    if (bytes == null) return;

    // 先に全件読み込んで検証する。ここで失敗しても今のデータには触れない
    final BackupData data;
    try {
      data = BackupService.decode(utf8.decode(bytes));
    } on FormatException catch (e) {
      _toast(AppSnackBar.error(e.message));
      return;
    } catch (e) {
      _toast(AppSnackBar.error('読み込みに失敗しました: ${AppErrors.describe(e)}'));
      return;
    }

    if (!mounted) return;
    final confirmed = await AppDialogs.confirm(
      context,
      title: 'バックアップから復元',
      message: 'アイテム ${data.items.length}件・プレイリスト ${data.playlists.length}件・'
          'タグ ${data.tags.length}件で、今のデータをすべて置き換えます。',
      confirmLabel: '置き換える',
      destructive: true,
    );
    // 確認の間に裏の処理が始まっていたら置き換えない
    if (!confirmed || !mounted || _replaceLocked) return;

    setState(() => _busy = true);
    try {
      ref.read(thumbnailQueueProvider.notifier).clear();
      await BackupService.restore(data);
      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);
      _toast(AppSnackBar.success('復元しました'));
      if (mounted) setState(() {});
      // サムネイル画像は端末固有なのでバックアップに含めていない。裏で取り直す
      _missingThumbs = null;
      ref.read(thumbnailQueueProvider.notifier).startAll();
    } catch (e) {
      _toast(AppSnackBar.error('復元に失敗しました: ${AppErrors.describe(e)}'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─── 端末に残しているもの ───

  Future<void> _pickCacheLimit() async {
    final current = MediaCache.limitMb;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('自動キャッシュの上限'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mb in MediaCache.limitOptionsMb)
                  RadioListTile<int>(value: mb, title: Text(_mbLabel(mb))),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    MediaCache.limitMb = picked;
    await MediaCache.enforceLimit();
    if (mounted) setState(() {});
  }

  Future<void> _clearMediaCache() async {
    final ok = await AppDialogs.confirm(
      context,
      title: '自動キャッシュを空にする',
      message: '次に再生したときにまた取得します。オフライン保存した曲は消えません。',
      confirmLabel: '空にする',
      destructive: true,
    );
    if (!ok) return;
    await MediaCache.clear();
    if (mounted) setState(() {});
    _toast(AppSnackBar.success('自動キャッシュを空にしました'));
  }

  static String _mbLabel(int mb) => mb == MediaCache.unlimitedMb
      ? '無制限'
      : mb >= 1024
          ? '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB'
          : '$mb MB';

  Future<void> _clearWaveformCache() async {
    final ok = await AppDialogs.confirm(
      context,
      title: '保存済みの波形を削除',
      message: '次に再生したときに音声を取得して作り直します。',
      confirmLabel: '削除',
      destructive: true,
    );
    if (!ok) return;
    await WaveformCache.clear();
    if (mounted) setState(() {});
    _toast(AppSnackBar.success('波形を削除しました'));
  }

  Future<void> _clearAllOfflineVideos() async {
    final cached =
        ref.read(loopItemsProvider).where((i) => i.isCached).toList();
    if (cached.isEmpty) {
      _toast(AppSnackBar.info('オフライン動画はありません'));
      return;
    }
    final ok = await AppDialogs.confirmDelete(context,
        title: 'オフライン動画をすべて削除',
        message: '${cached.length}件の保存済み動画と字幕を削除します。'
            '曲の登録やAB区間はそのまま残ります。');
    if (!ok) return;
    final notifier = ref.read(loopItemsProvider.notifier);
    for (final item in cached) {
      await notifier.clearCache(item.id);
    }
    if (mounted) setState(() {});
    _toast(AppSnackBar.success('${cached.length}件のオフライン動画を削除しました'));
  }

  Future<void> _clearAllData() async {
    final confirmed = await AppDialogs.confirm(
      context,
      title: 'すべてのデータを削除',
      message: 'アイテム・プレイリスト・タグがすべて削除されます。\n'
          'この操作は元に戻せません。',
      confirmLabel: '削除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    final really = await AppDialogs.confirm(
      context,
      title: '本当に削除しますか？',
      message: '${AppBoxes.loopItems.length}件のアイテム、'
          '${AppBoxes.playlists.length}件のプレイリスト、'
          '${AppBoxes.tags.length}件のタグが完全に失われます。',
      confirmLabel: '完全に削除',
      destructive: true,
    );
    if (!really || !mounted || _replaceLocked) return;

    setState(() => _busy = true);
    try {
      ref.read(thumbnailQueueProvider.notifier).clear();
      _missingThumbs = null;
      await AppBoxes.loopItems.clear();
      await AppBoxes.playlists.clear();
      await AppBoxes.tags.clear();
      await LocalMediaImport.clearAll();
      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);

      _toast(AppSnackBar.success('すべてのデータを削除しました'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 右端のごみ箱（null なら消すものが無いので出さない）
  Widget? _trash(String tooltip, VoidCallback? onPressed) => onPressed == null
      ? null
      : IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: tooltip,
          onPressed: _busy ? null : onPressed,
        );

  /// 群の 1 行目: 今どれだけ使っているかと、まとめて消すごみ箱（[value] が null なら計算中）
  Widget _usageRow({
    required String? value,
    required String clearLabel,
    required VoidCallback? onClear,
  }) =>
      SettingsRow(
        icon: Icons.data_usage,
        title: '使用量',
        subtitle: value ?? '計算中…',
        trailing: _trash(clearLabel, onClear),
      );

  /// まとめて取得の状況と、一時停止・再開・取得のボタン
  Widget _thumbnailRow() {
    final queue = ref.read(thumbnailQueueProvider.notifier);
    final s = ref.watch(thumbnailQueueProvider);
    if (s != null) {
      return SettingsRow(
        icon: Icons.image_outlined,
        title: s.paused ? '一時停止中' : '取得中',
        subtitle: s.paused
            ? '残り ${s.total - s.done} 件'
            : ThumbnailQueueBar.progressLabel(s),
        trailing: IconButton(
          icon: Icon(s.paused ? Icons.play_arrow : Icons.pause),
          tooltip: s.paused ? '再開' : '一時停止',
          onPressed: s.paused ? queue.resume : queue.pause,
        ),
      );
    }
    _missingThumbs ??= ref
        .read(loopItemsProvider.notifier)
        .missingThumbnails()
        .then((items) => items.length);
    return FutureBuilder<int>(
      future: _missingThumbs,
      builder: (_, snap) {
        final count = snap.data;
        return SettingsRow(
          icon: Icons.image_outlined,
          title: '未取得',
          subtitle: count == null ? '計算中…' : '$count 件',
          trailing: (count ?? 0) == 0
              ? const SizedBox.shrink()
              : IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'サムネイルを取得',
                  onPressed: queue.startAll,
                ),
        );
      },
    );
  }

  static String _mb(int bytes, {int digits = 1}) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(digits)} MB';

  @override
  Widget build(BuildContext context) {
    final keep = DataSettingsScreen.keepOfflineVideos;
    final replaceLocked = ref.watch(
            thumbnailQueueProvider.select((s) => s?.running ?? false)) ||
        ref.watch(bulkAnalysisProvider.select((s) => s != null));
    ref.listen(thumbnailQueueProvider.select((s) => s == null), (_, idle) {
      if (idle) setState(() => _missingThumbs = null);
    });
    final backup = SettingsGroup(
      title: 'バックアップ',
      children: [
        SettingsRow(
          icon: Icons.upload_file,
          title: 'バックアップを書き出す',
          onTap: _busy ? null : _exportData,
        ),
        SettingsRow(
          icon: Icons.download,
          title: 'バックアップから復元',
          onTap: _busy || replaceLocked ? null : _importData,
        ),
      ],
    );
    final offline = SettingsGroup(
      title: 'オフライン動画',
      children: [
        FutureBuilder<int>(
          future: CacheService().totalCacheSize(),
          builder: (_, snap) => _usageRow(
            value: snap.hasData ? _mb(snap.data!) : null,
            clearLabel: 'オフライン動画をすべて削除',
            onClear: (snap.data ?? 0) == 0 ? null : _clearAllOfflineVideos,
          ),
        ),
        SettingsSwitchRow(
          icon: Icons.sd_storage,
          title: '端末に残す',
          value: keep,
          onChanged: (v) {
            AppBoxes.settings.put(SettingsKeys.cacheToDocuments, v);
            setState(() {});
            // 保存先は保存時に決まるので、既存の動画は移動しない
            _toast(AppSnackBar.info('これから保存する動画から適用されます'));
          },
        ),
      ],
    );
    final thumbnails = SettingsGroup(
      title: 'サムネイル',
      children: [_thumbnailRow()],
    );
    // 一度聴いた曲の映像・高音質の音声（MediaCache）。消えてよい使い捨て。
    // 長い曲（MediaCache.maxDuration 超）は残さない
    final cache = SettingsGroup(
      title: '自動キャッシュ',
      children: [
        FutureBuilder<int>(
          future: MediaCache.totalBytes(),
          builder: (_, snap) => _usageRow(
            value: snap.hasData ? _mb(snap.data!, digits: 0) : null,
            clearLabel: '自動キャッシュを空にする',
            onClear: (snap.data ?? 0) == 0 ? null : _clearMediaCache,
          ),
        ),
        // 超えたら古い順に消す
        SettingsRow(
          icon: Icons.vertical_align_top,
          title: '上限',
          subtitle: _mbLabel(MediaCache.limitMb),
          onTap: _pickCacheLimit,
        ),
      ],
    );
    final waveform = SettingsGroup(
      title: '波形',
      children: [
        // 波形は 4KB/曲 なので上限は設けない。作り直したいときだけ消す
        FutureBuilder<(int, int)>(
          future: WaveformCache.stats(),
          builder: (_, snap) {
            final (count, bytes) = snap.data ?? (0, 0);
            return _usageRow(
              value: snap.hasData
                  ? '$count 曲 · ${(bytes / 1024).toStringAsFixed(0)} KB'
                  : null,
              clearLabel: '保存済みの波形を削除',
              onClear: count == 0 ? null : _clearWaveformCache,
            );
          },
        ),
      ],
    );
    // 取り返しのつかない操作は、ふだんの操作から離して最後に
    final deleteAll = SettingsGroup(
      children: [
        SettingsRow(
          icon: Icons.delete_forever,
          title: 'すべてのデータを削除',
          danger: true,
          showChevron: false,
          onTap: _busy || replaceLocked ? null : _clearAllData,
        ),
      ],
    );
    return Stack(
      children: [
        SettingsPage(
          title: DataSettingsScreen.title,
          // 横は 3 列: 曲の一覧まるごとの操作（バックアップ・すべて削除）/ オフライン動画 /
          // 消えてよい使い捨て（自動キャッシュ・波形）
          wideColumns: [
            [backup, deleteAll],
            [offline, thumbnails],
            [cache, waveform],
          ],
          children: [backup, offline, thumbnails, cache, waveform, deleteAll],
        ),
        if (_busy)
          Container(
            color: Colors.black38,
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
