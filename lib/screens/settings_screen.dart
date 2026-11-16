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
import '../widgets/player/more_tile.dart';
import '../widgets/settings/settings_parts.dart';
import 'settings/advanced_settings_screen.dart';
import 'settings/backup_settings_screen.dart';
import 'settings/dj_mix_settings_screen.dart';
import 'settings/storage_settings_screen.dart';

/// 設定のトップ。四角い大きなボタン（[MoreTile]）を敷き詰め、残りは各ページへ。
/// 今の値は短いものだけボタンに出す
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _versionTapCount = 0;

  // 描き直すたびに取り直さない
  Future<int> _cacheSize = CacheService().totalCacheSize();
  final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  void _toast(AppToastMessage bar) {
    if (mounted) AppToast.instance.show(bar);
  }

  /// ページを開く。戻ってきたら保存の容量を取り直す（中で消したり保存先を変えたりする）
  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    setState(() {
      _cacheSize = CacheService().totalCacheSize();
    });
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

    final tiles = <Widget>[
      MoreTile(
        icon: isDark ? Icons.dark_mode : Icons.light_mode,
        label: 'ダークモード',
        active: isDark,
        onTap: () => ref.read(themeProvider.notifier).value = !isDark,
      ),
      MoreTile(
        icon: Icons.multitrack_audio,
        label: 'DJ ミックス',
        value: DjMixSettingsScreen.crossfadeLabel(ref.watch(crossfadeProvider)),
        onTap: () => _push(const DjMixSettingsScreen()),
      ),
      MoreTile(
        icon: Icons.forward_10,
        label: '早送り・巻き戻し',
        value: '$seekStep秒',
        onTap: _pickSeekStep,
      ),
      FutureBuilder<int>(
        future: _cacheSize,
        builder: (_, snap) => MoreTile(
          icon: Icons.sd_storage,
          label: 'オフライン保存',
          value: snap.hasData
              ? '${(snap.data! / 1024 / 1024).toStringAsFixed(1)} MB'
              : '計算中…',
          onTap: () => _push(const StorageSettingsScreen()),
        ),
      ),
      MoreTile(
        icon: Icons.backup_outlined,
        label: 'バックアップ',
        onTap: () => _push(const BackupSettingsScreen()),
      ),
      FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (_, snap) => MoreTile(
          icon: Icons.system_update,
          label: 'アップデートを確認',
          value: 'v${snap.data?.version ?? '…'}',
          onTap: () {
            if (_onVersionTap()) return;
            _toast(AppSnackBar.info('最新版を確認中...'));
            UpdateService.checkForUpdate(context, manual: true);
          },
        ),
      ),
      MoreTile(
        icon: Icons.tune,
        label: '詳細設定',
        onTap: () => _push(const AdvancedSettingsScreen()),
      ),
    ];

    return SettingsPage(
      title: '設定',
      children: [
        // 四角い大きなボタンを敷き詰める（狭い画面は 2 列、広ければ 3 列。真ん中に寄せる）
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _gridMaxWidth),
            child: LayoutBuilder(
              builder: (context, c) => GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                crossAxisCount: c.maxWidth < _threeColumnsWidth ? 2 : 3,
                mainAxisSpacing: AppSpacing.lg,
                crossAxisSpacing: AppSpacing.lg,
                children: tiles,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xl),
          child: Text('曲 $items · プレイリスト $playlists · タグ $tags',
              textAlign: TextAlign.center, style: textTheme.labelSmall),
        ),
      ],
    );
  }

  /// この幅から 3 列（それより狭い縦の電話は 2 列）
  static const double _threeColumnsWidth = 480;

  /// タイルを敷く幅の上限（広い画面で大きくなりすぎないように）
  static const double _gridMaxWidth = 760;
}
