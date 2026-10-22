import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snack_bar.dart';
import '../models/loop_item.dart';
import '../providers/easter_egg_provider.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../services/cache_service.dart';
import '../services/update_service.dart';
import '../widgets/player/first_verse_sheet.dart';
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

  void _toast(SnackBar bar) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(bar);
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

  Future<void> _pickVerseRange() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) => AlertDialog(
          title: const Text('1番を探す範囲'),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              VerseRangeFields(
                range: ref.watch(verseSearchRangeProvider),
                onChanged: (v) =>
                    ref.read(verseSearchRangeProvider.notifier).value = v,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => ref.read(verseSearchRangeProvider.notifier).value =
                  VerseRangeNotifier.defaultRange,
              child: const Text('既定に戻す'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('閉じる'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── アプリ情報 ───

  void _onVersionTap() {
    _versionTapCount++;
    if (_versionTapCount < 5) return;
    _versionTapCount = 0;
    final unlocked = ref.read(easterEggProvider.notifier).unlockStats();
    if (unlocked) {
      _toast(AppSnackBar.success('🎉 隠しステータスがアンロックされました！'));
    }
    _showStatsScreen();
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
            // 1番モードで「1 番の終わり」を自動で探す範囲（曲ごとの手直しは「1番」の長押し）
            SettingsRow(
              icon: Icons.looks_one_outlined,
              title: '1番を探す範囲',
              subtitle: VerseRangeNotifier.label(ref.watch(verseSearchRangeProvider)),
              onTap: _pickVerseRange,
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
                    _onVersionTap();
                    UpdateService.checkForUpdate(context);
                    _toast(AppSnackBar.info('最新版を確認中...'));
                  },
                );
              },
            ),
            SettingsRow(
              icon: Icons.tune,
              title: '詳細設定',
              subtitle: '表示 · 危険な操作 · 開発者向け',
              onTap: () => _push(const AdvancedSettingsScreen()),
            ),
          ],
        ),
      ],
    );
  }

  // ─── 隠しステータス画面 ───

  void _showStatsScreen() {
    final items = AppBoxes.loopItems.values.toList();
    final playlists = AppBoxes.playlists.values.toList();
    final tags = AppBoxes.tags.values.toList();

    // 集計
    final totalItems = items.length;
    final totalPlaylists = playlists.length;
    final totalTags = tags.length;
    final totalPlayCount =
        items.fold<int>(0, (sum, i) => sum + i.playCount);
    final totalRegions =
        items.fold<int>(0, (sum, i) => sum + i.regions.length);
    final youtubeCount =
        items.where((i) => i.isYouTube).length;
    final localCount = items.where((i) => i.isLocal).length;

    // 最もリピートした曲
    LoopItem? mostPlayed;
    if (items.isNotEmpty) {
      mostPlayed = items.reduce(
          (a, b) => a.playCount >= b.playCount ? a : b);
    }

    // 最古のアイテム
    LoopItem? oldest;
    if (items.isNotEmpty) {
      oldest = items.reduce(
          (a, b) => a.createdAt.isBefore(b.createdAt) ? a : b);
    }

    // 総再生時間の推定（再生カウント × 平均3分）
    final estimatedMinutes = totalPlayCount * 3;

    final textTheme = Theme.of(context).textTheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.analytics_outlined, size: 20),
            const SizedBox(width: 8),
            Text('隠しステータス', style: textTheme.titleMedium),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statLine('登録曲数', '$totalItems 曲（YouTube: $youtubeCount / ローカル: $localCount）'),
              _statLine('プレイリスト', '$totalPlaylists 個'),
              _statLine('タグ', '$totalTags 個'),
              _statLine('AB区間', '$totalRegions 個'),
              _statLine('総再生回数', '$totalPlayCount 回'),
              _statLine('推定練習時間', '約${estimatedMinutes ~/ 60}時間${estimatedMinutes % 60}分'),
              if (mostPlayed != null && mostPlayed.playCount > 0)
                _statLine('最多リピート', '${mostPlayed.title}（${mostPlayed.playCount}回）'),
              if (oldest != null)
                _statLine('最古の登録', '${oldest.createdAt.year}/${oldest.createdAt.month}/${oldest.createdAt.day}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Widget _statLine(String label, String value) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: textTheme.labelSmall),
          Text(value, style: textTheme.bodyMedium),
        ],
      ),
    );
  }
}
