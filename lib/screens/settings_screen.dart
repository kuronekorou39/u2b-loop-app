import 'dart:math';

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
import '../widgets/glass_scaffold.dart';
import 'settings/advanced_settings_screen.dart';
import 'settings/backup_settings_screen.dart';
import 'settings/dj_mix_settings_screen.dart';
import 'settings/storage_settings_screen.dart';

/// 設定のトップ。四角い大きなボタン（[MoreTile]）を敷き詰め、残りは各ページへ。
/// 今の値は短いものだけボタンに出す。縦でも横でもスクロールせずに全部収め、
/// 画面の端まで詰めない（[gridFor]）
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  /// ボタンの間隔
  static const gridGap = AppSpacing.lg;

  /// ボタンの 1 辺の上限（広い画面で大きくなりすぎないように）
  static const maxTileSide = 200.0;

  /// [count] 個の正方形のボタンを [area] に全部収める並べ方。
  /// 列数を 1 から順に試し、ボタンがいちばん大きくなる列数にする
  /// （縦の電話は 2 列 × 3 行、横向きの電話は 1 行になる）
  static ({int columns, double side}) gridFor(Size area, int count) {
    var best = (columns: 1, side: 0.0);
    for (var columns = 1; columns <= count; columns++) {
      final rows = (count / columns).ceil();
      final side = min((area.width - gridGap * (columns - 1)) / columns,
          (area.height - gridGap * (rows - 1)) / rows);
      if (side > best.side) best = (columns: columns, side: side);
    }
    return (
      columns: best.columns,
      side: best.side.clamp(0.0, maxTileSide).floorToDouble(),
    );
  }

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
    final textTheme = Theme.of(context).textTheme;
    final items = AppBoxes.loopItems.length;
    final playlists = AppBoxes.playlists.length;
    final tags = AppBoxes.tags.length;

    final tiles = <Widget>[
      MoreTile(
        icon: Icons.multitrack_audio,
        label: 'DJ ミックス',
        value: DjMixSettingsScreen.crossfadeLabel(ref.watch(crossfadeProvider)),
        onTap: () => _push(const DjMixSettingsScreen()),
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
          label: 'アップデート',
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

    return GlassScaffold(
      title: Text('設定', style: textTheme.titleMedium),
      // ダーク / ライトの切り替えは右上に（ボタンの並びには入れない。ラベルなし）。
      // スキップ秒数は再生画面の ±N 秒ボタンの長押しで選ぶ
      actions: [
        IconButton(
          icon: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
          tooltip: isDark ? 'ライトモードにする' : 'ダークモードにする',
          onPressed: () => ref.read(themeProvider.notifier).value = !isDark,
        ),
      ],
      bodyBuilder: (context) {
        final padding = MediaQuery.paddingOf(context);
        final viewPadding = MediaQuery.viewPaddingOf(context);
        return Padding(
          // 画面の端まで詰めない
          padding: EdgeInsets.fromLTRB(
            _margin + viewPadding.left,
            padding.top + _margin,
            _margin + viewPadding.right,
            padding.bottom + _margin,
          ),
          child: LayoutBuilder(builder: (context, c) {
            final grid = SettingsScreen.gridFor(
                Size(c.maxWidth, c.maxHeight - _footerHeight), tiles.length);
            return Column(
              children: [
                // 左右は真ん中に寄せる。最後の行は左から
                SizedBox(
                  width: grid.side * grid.columns +
                      SettingsScreen.gridGap * (grid.columns - 1),
                  child: Wrap(
                    spacing: SettingsScreen.gridGap,
                    runSpacing: SettingsScreen.gridGap,
                    children: [
                      for (final tile in tiles)
                        SizedBox.square(dimension: grid.side, child: tile),
                    ],
                  ),
                ),
                SizedBox(
                  height: _footerHeight,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Text('曲 $items · プレイリスト $playlists · タグ $tags',
                        style: textTheme.labelSmall),
                  ),
                ),
              ],
            );
          }),
        );
      },
    );
  }

  /// ボタンの集まりの外の余白（上下左右）
  static const double _margin = AppSpacing.xxl;

  /// ボタンの下の「曲 N · …」の行に取っておく高さ
  static const double _footerHeight = 36;
}
