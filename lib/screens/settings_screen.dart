import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snack_bar.dart';
import '../providers/debug_mode_provider.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../services/cache_service.dart';
import '../services/update_service.dart';
import '../widgets/settings/settings_parts.dart';
import 'settings/advanced_settings_screen.dart';
import 'settings/backup_settings_screen.dart';
import 'settings/dj_mix_settings_screen.dart';
import 'settings/storage_settings_screen.dart';

/// 設定のトップ。スクロール無しで収まる数だけ置き、残りは各ページへ。
/// 各行の説明文に今の設定を要約して、開かなくても状態が分かるようにする
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _versionTapCount = 0;

  void _toast(AppToastMessage bar) {
    if (mounted) AppToast.instance.show(bar);
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _pickSeekStep() async {
    final current = ref.read(seekStepProvider);
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('スキップ秒数'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in SeekStepNotifier.options)
                  RadioListTile<int>(value: s, title: Text('$s秒')),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) ref.read(seekStepProvider.notifier).value = picked;
  }

  // ─── アプリ情報 ───

  /// バージョン行を続けて 5 回押すとデバッグモード（詳細設定に「デバッグ」の群が出る）
  /// 戻り値はデバッグモードに入ったか（その回は更新確認の通知で上書きしない）
  bool _onVersionTap() {
    _versionTapCount++;
    if (_versionTapCount < 5) return false;
    _versionTapCount = 0;
    ref.read(debugModeProvider.notifier).enable();
    _toast(AppSnackBar.success('デバッグモードをオンにしました（詳細設定の中）'));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(themeProvider);
    final seekStep = ref.watch(seekStepProvider);
    final textTheme = Theme.of(context).textTheme;
    final items = AppBoxes.loopItems.length;
    final playlists = AppBoxes.playlists.length;
    final tags = AppBoxes.tags.length;

    return SettingsPage(
      title: '設定',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
          child: Text('曲 $items · プレイリスト $playlists · タグ $tags',
              style: textTheme.labelSmall),
        ),
        SettingsGroup(
          children: [
            SettingsSwitchRow(
              icon: isDark ? Icons.dark_mode : Icons.light_mode,
              title: 'ダークモード',
              value: isDark,
              onChanged: (v) => ref.read(themeProvider.notifier).value = v,
            ),
          ],
        ),
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.multitrack_audio,
              title: 'DJ ミックス',
              subtitle: DjMixSettingsScreen.summary(ref),
              onTap: () => _push(const DjMixSettingsScreen()),
            ),
            SettingsRow(
              icon: Icons.forward_10,
              title: '早送り・巻き戻し',
              subtitle: '$seekStep秒',
              onTap: _pickSeekStep,
            ),
          ],
        ),
        SettingsGroup(
          children: [
            FutureBuilder<int>(
              future: CacheService().totalCacheSize(),
              builder: (_, snap) {
                final mb = ((snap.data ?? 0) / 1024 / 1024).toStringAsFixed(1);
                final keep = StorageSettingsScreen.keepOfflineVideos;
                return SettingsRow(
                  icon: Icons.sd_storage,
                  title: 'オフライン保存',
                  subtitle:
                      '${keep ? '端末に残す' : '一時領域'} · ${snap.hasData ? '$mb MB' : '計算中…'}',
                  onTap: () => _push(const StorageSettingsScreen()),
                );
              },
            ),
            SettingsRow(
              icon: Icons.backup_outlined,
              title: 'バックアップ',
              subtitle: '書き出し / 復元',
              onTap: () => _push(const BackupSettingsScreen()),
            ),
          ],
        ),
        SettingsGroup(
          children: [
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (_, snap) {
                final version = snap.data?.version ?? '…';
                return SettingsRow(
                  icon: Icons.system_update,
                  title: 'アップデートを確認',
                  subtitle: 'v$version',
                  onTap: () {
                    if (_onVersionTap()) return;
                    _toast(AppSnackBar.info('最新版を確認中...'));
                    UpdateService.checkForUpdate(context, manual: true);
                  },
                );
              },
            ),
            SettingsRow(
              icon: Icons.tune,
              title: '詳細設定',
              subtitle: ref.watch(debugModeProvider)
                  ? '表示 · 再生 · 危険な操作 · デバッグ'
                  : '表示 · 再生 · 危険な操作',
              onTap: () => _push(const AdvancedSettingsScreen()),
            ),
          ],
        ),
      ],
    );
  }
}
