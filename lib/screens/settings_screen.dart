import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snack_bar.dart';
import '../providers/debug_mode_provider.dart';
import '../providers/theme_provider.dart';
import '../services/update_service.dart';
import '../widgets/player/more_tile.dart';
import '../widgets/glass_scaffold.dart';
import 'settings/advanced_settings_screen.dart';
import 'settings/data_settings_screen.dart';
import 'settings/debug_settings_screen.dart';
import 'settings/dj_mix_settings_screen.dart';

/// 設定のトップ。四角い大きなボタン（[MoreTile]）を敷き詰め、残りは各ページへ。
/// アップデートは次の画面へ進むボタンではない（その場で確認する。ふだんは起動時に自動）ので、
/// ボタンの並びには入れず、下の真ん中に小さな札（バージョン + 更新を確認）で置く。
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
  /// （3 つなら縦の電話は縦に 1 列、横向きの電話は 1 行。デバッグモードで 4 つなら
  /// 縦の電話は 2 列 × 2 行）
  static ({int columns, double side}) gridFor(Size area, int count) {
    var best = (columns: 1, side: 0.0);
    for (var columns = 1; columns <= count; columns++) {
      final rows = (count / columns).ceil();
      final side = min(
        (area.width - gridGap * (columns - 1)) / columns,
        (area.height - gridGap * (rows - 1)) / rows,
      );
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
  final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  void _toast(AppToastMessage bar) {
    if (mounted) AppToast.instance.show(bar);
  }

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  // ─── アプリ情報 ───

  /// アップデートの札を続けて 5 回押すとデバッグモード（トップに「デバッグ」のボタンが出る）
  /// 戻り値はデバッグモードに入ったか（その回は更新確認の通知で上書きしない）
  bool _onVersionTap() {
    _versionTapCount++;
    if (_versionTapCount < 5) return false;
    _versionTapCount = 0;
    ref.read(debugModeProvider.notifier).enable();
    _toast(AppSnackBar.success('デバッグモードをオンにしました'));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(themeProvider);
    final textTheme = Theme.of(context).textTheme;
    final items = AppBoxes.loopItems.length;
    final playlists = AppBoxes.playlists.length;
    final tags = AppBoxes.tags.length;

    // 設定する系（DJ ミックス・表示と再生）の後にデータ（バックアップ・保存した動画など）。
    // デバッグモードの間だけ最後にデバッグ
    final tiles = <Widget>[
      MoreTile(
        icon: Icons.multitrack_audio,
        label: 'DJ ミックス',
        onTap: () => _push(const DjMixSettingsScreen()),
      ),
      MoreTile(
        icon: Icons.tune,
        label: AdvancedSettingsScreen.title,
        onTap: () => _push(const AdvancedSettingsScreen()),
      ),
      MoreTile(
        icon: Icons.sd_storage,
        label: DataSettingsScreen.title,
        onTap: () => _push(const DataSettingsScreen()),
      ),
      if (ref.watch(debugModeProvider))
        MoreTile(
          icon: Icons.bug_report_outlined,
          label: 'デバッグ',
          onTap: () => _push(const DebugSettingsScreen()),
        ),
    ];

    return GlassScaffold(
      title: Text('設定', style: textTheme.titleMedium),
      // ダーク / ライトの切り替えは右上に（ボタンの並びには入れない。ラベルなし）。
      // スキップ秒数は再生画面の ±N 秒ボタンの長押しで選ぶ
      actions: [
        // 右端に寄せすぎない（ボタンの並びの右端あたりに）
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.lg),
          child: IconButton(
            icon: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
            tooltip: isDark ? 'ライトモードにする' : 'ダークモードにする',
            onPressed: () => ref.read(themeProvider.notifier).value = !isDark,
          ),
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
          child: LayoutBuilder(
            builder: (context, c) {
              final grid = SettingsScreen.gridFor(
                Size(c.maxWidth, c.maxHeight - _footerHeight),
                tiles.length,
              );
              // 本文は Stack の中で幅が緩いので、幅いっぱいに取ってから真ん中に寄せる
              return SizedBox(
                width: c.maxWidth,
                child: Column(
                  children: [
                    // 左右は真ん中に寄せる。最後の行は左から
                    SizedBox(
                      width:
                          grid.side * grid.columns +
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '曲 $items · プレイリスト $playlists · タグ $tags',
                            style: textTheme.titleSmall,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _updateChip(textTheme),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// ボタンの集まりの外の余白（上下左右）
  static const double _margin = AppSpacing.xxl;

  /// ボタンの下（アップデートの札と「曲 N · …」の行）に取っておく高さ
  static const double _footerHeight = 76;

  /// 「v1.2.3 · 更新を確認」の札。押すとその場で確認（5 回続けて押すとデバッグモード）
  Widget _updateChip(TextTheme textTheme) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snap) => Material(
        color: onSurface.withValues(alpha: 0.08),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (_onVersionTap() || !UpdateService.supported) return;
            _toast(AppSnackBar.info('最新版を確認中...'));
            UpdateService.checkForUpdate(context, manual: true);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.md,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.system_update,
                  size: AppIconSizes.md,
                  color: AppTheme.accentGreen,
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  'v${UpdateService.displayVersion(snap.data?.version ?? '…')}',
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (UpdateService.supported)
                  Text('  ·  更新を確認', style: textTheme.labelMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
