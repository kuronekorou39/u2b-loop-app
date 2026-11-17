import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_boxes.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../providers/data_provider.dart';
import '../../services/cache_service.dart';
import '../../services/playback/media_cache.dart';
import '../../services/waveform_cache.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「保存データ」: オフライン動画・自動キャッシュ・保存済みの波形と、その削除。
/// 行には今の値だけを出し、説明は確かめるダイアログに書く。消すものは右端のごみ箱
class StorageSettingsScreen extends ConsumerStatefulWidget {
  const StorageSettingsScreen({super.key});

  /// ページの名前（トップのボタンと同じ）
  static const title = '保存データ';

  /// オフライン動画の保存先（true=端末に残す[documents] / false=一時領域[cache]）
  static bool get keepOfflineVideos =>
      AppBoxes.settings.get(SettingsKeys.cacheToDocuments, defaultValue: true)
          as bool;

  @override
  ConsumerState<StorageSettingsScreen> createState() =>
      _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends ConsumerState<StorageSettingsScreen> {
  bool _busy = false;

  void _toast(AppToastMessage bar) {
    if (mounted) AppToast.instance.show(bar);
  }

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
    if (!really) return;

    setState(() => _busy = true);
    try {
      await AppBoxes.loopItems.clear();
      await AppBoxes.playlists.clear();
      await AppBoxes.tags.clear();
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

  static String _mb(int bytes, {int digits = 1}) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(digits)} MB';

  @override
  Widget build(BuildContext context) {
    final keep = StorageSettingsScreen.keepOfflineVideos;
    return Stack(
      children: [
        SettingsPage(
          title: StorageSettingsScreen.title,
          children: [
            SettingsGroup(
              title: 'オフライン動画',
              children: [
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
                FutureBuilder<int>(
                  future: CacheService().totalCacheSize(),
                  builder: (_, snap) => SettingsRow(
                    icon: Icons.folder_open,
                    title: '使用量',
                    subtitle: snap.hasData ? _mb(snap.data!) : '計算中…',
                    trailing: _trash('オフライン動画をすべて削除',
                        (snap.data ?? 0) == 0 ? null : _clearAllOfflineVideos),
                  ),
                ),
              ],
            ),
            // 一度聴いた曲の映像・高音質の音声（MediaCache）。消えてよい使い捨て。
            // 長い曲（MediaCache.maxDuration 超）は残さない
            SettingsGroup(
              title: '自動キャッシュ',
              children: [
                FutureBuilder<int>(
                  future: MediaCache.totalBytes(),
                  builder: (_, snap) => SettingsRow(
                    icon: Icons.cached,
                    title: '使用量',
                    subtitle:
                        snap.hasData ? _mb(snap.data!, digits: 0) : '計算中…',
                    trailing: _trash('自動キャッシュを空にする',
                        (snap.data ?? 0) == 0 ? null : _clearMediaCache),
                  ),
                ),
                // 超えたら古い順に消す
                SettingsRow(
                  icon: Icons.data_usage,
                  title: '上限',
                  subtitle: _mbLabel(MediaCache.limitMb),
                  onTap: _pickCacheLimit,
                ),
              ],
            ),
            SettingsGroup(
              title: '波形',
              children: [
                // 波形は 4KB/曲 なので上限は設けない。作り直したいときだけ消す
                FutureBuilder<(int, int)>(
                  future: WaveformCache.stats(),
                  builder: (_, snap) {
                    final (count, bytes) = snap.data ?? (0, 0);
                    return SettingsRow(
                      icon: Icons.graphic_eq,
                      title: '保存済み',
                      subtitle: snap.hasData
                          ? '$count 曲 · ${(bytes / 1024).toStringAsFixed(0)} KB'
                          : '計算中…',
                      trailing: _trash('保存済みの波形を削除',
                          count == 0 ? null : _clearWaveformCache),
                    );
                  },
                ),
              ],
            ),
            // 取り返しのつかない操作は、ふだんの操作から離して最後に
            SettingsGroup(
              children: [
                SettingsRow(
                  icon: Icons.delete_forever,
                  title: 'すべてのデータを削除',
                  danger: true,
                  showChevron: false,
                  onTap: _busy ? null : _clearAllData,
                ),
              ],
            ),
          ],
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
