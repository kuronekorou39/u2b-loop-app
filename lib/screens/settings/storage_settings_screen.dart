import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_boxes.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../services/cache_service.dart';
import '../../services/waveform_cache.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「オフライン保存」: 保存先・容量・保存済みの波形
class StorageSettingsScreen extends ConsumerStatefulWidget {
  const StorageSettingsScreen({super.key});

  /// オフライン動画の保存先（true=端末に残す[documents] / false=一時領域[cache]）
  static bool get keepOfflineVideos =>
      AppBoxes.settings.get(SettingsKeys.cacheToDocuments, defaultValue: false)
          as bool;

  @override
  ConsumerState<StorageSettingsScreen> createState() =>
      _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends ConsumerState<StorageSettingsScreen> {
  void _toast(SnackBar bar) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(bar);
  }

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

  @override
  Widget build(BuildContext context) {
    final keep = StorageSettingsScreen.keepOfflineVideos;
    return SettingsPage(
      title: 'オフライン保存',
      children: [
        SettingsGroup(
          children: [
            SettingsSwitchRow(
              icon: Icons.sd_storage,
              title: 'オフライン動画を端末に残す',
              subtitle: keep ? 'アプリを削除するまで残ります' : '容量不足で消えることがあります',
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
              builder: (_, snap) {
                final waiting = snap.connectionState == ConnectionState.waiting;
                final mb = ((snap.data ?? 0) / 1024 / 1024).toStringAsFixed(1);
                return SettingsRow(
                  icon: Icons.folder_open,
                  title: 'オフライン動画の容量',
                  subtitle: waiting ? '計算中…' : '$mb MB',
                );
              },
            ),
          ],
        ),
        SettingsGroup(
          children: [
            // 波形は 4KB/曲 なので上限は設けない。作り直したいときだけ消す
            FutureBuilder<(int, int)>(
              future: WaveformCache.stats(),
              builder: (_, snap) {
                final (count, bytes) = snap.data ?? (0, 0);
                final kb = (bytes / 1024).toStringAsFixed(0);
                return SettingsRow(
                  icon: Icons.graphic_eq,
                  title: '保存済みの波形',
                  subtitle: snap.hasData
                      ? '$count 曲 · $kb KB。タップで削除して作り直す'
                      : '計算中…',
                  onTap: count == 0 ? null : _clearWaveformCache,
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}
