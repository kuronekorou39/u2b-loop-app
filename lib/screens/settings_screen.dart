import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/storage/app_boxes.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_dialogs.dart';
import '../core/ui/app_snack_bar.dart';
import '../models/loop_item.dart';
import '../providers/data_provider.dart';
import '../providers/easter_egg_provider.dart';
import '../providers/glass_provider.dart';
import '../providers/loading_animation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../services/backup_service.dart';
import '../services/cache_service.dart';
import '../services/update_service.dart';
import '../services/waveform_cache.dart';
import '../widgets/loading_animations/loading_animation.dart';
import '../widgets/loading_animations/loading_animation_widget.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;
  int _versionTapCount = 0;

  int get _itemCount => AppBoxes.loopItems.length;
  int get _playlistCount => AppBoxes.playlists.length;
  int get _tagCount => AppBoxes.tags.length;

  /// オフライン動画の保存先（true=端末に残す[documents] / false=一時領域[cache]）
  bool get _keepOfflineVideos =>
      AppBoxes.settings.get(SettingsKeys.cacheToDocuments, defaultValue: false)
          as bool;

  void _toast(SnackBar bar) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(bar);
  }

  // ─── 再生 ───

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

  static String _crossfadeLabel(int seconds) =>
      seconds == 0 ? 'オフ' : '$seconds秒';

  Future<void> _pickCrossfade() async {
    final current = ref.read(crossfadeProvider);
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('クロスフェード'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in CrossfadeNotifier.options)
                  RadioListTile<int>(
                      value: s, title: Text(_crossfadeLabel(s))),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null) ref.read(crossfadeProvider.notifier).value = picked;
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

  // ─── バックアップ ───

  Future<void> _exportData() async {
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
      _toast(AppSnackBar.error('書き出しに失敗しました: $e'));
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
      _toast(AppSnackBar.error('読み込みに失敗しました: $e'));
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
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await BackupService.restore(data);
      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);
      _toast(AppSnackBar.success('復元しました'));
      if (mounted) setState(() {});
      // サムネイル画像は端末固有なのでバックアップに含めていない。取り直す
      _repairThumbnailsWithProgress();
    } catch (e) {
      _toast(AppSnackBar.error('復元に失敗しました: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatEta(Duration d) {
    if (d.inHours > 0) return '約${d.inHours}時間${d.inMinutes % 60}分';
    if (d.inMinutes > 0) return '約${d.inMinutes}分';
    return '1分未満';
  }

  void _repairThumbnailsWithProgress() {
    final textTheme = Theme.of(context).textTheme;
    final doneNotifier = ValueNotifier<int>(0);
    final totalNotifier = ValueNotifier<int>(0);
    final etaNotifier = ValueNotifier<String>('');
    final startTime = DateTime.now();

    showDialog(
      context: context,
      barrierDismissible: false,
      // 戻るボタンで閉じられると、完了時のpopが設定画面自体を閉じてしまう
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: totalNotifier,
            builder: (_, total, _) => ValueListenableBuilder<int>(
              valueListenable: doneNotifier,
              builder: (_, done, _) => ValueListenableBuilder<String>(
                valueListenable: etaNotifier,
                builder: (_, eta, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: AppSpacing.xl),
                        Expanded(
                          child: Text('サムネイルを復元中...',
                              style: textTheme.bodyLarge),
                        ),
                      ],
                    ),
                    if (total > 0) ...[
                      const SizedBox(height: AppSpacing.lg),
                      LinearProgressIndicator(value: done / total),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('$done / $total', style: textTheme.bodySmall),
                          if (eta.isNotEmpty)
                            Text('残り $eta', style: textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    ref.read(loopItemsProvider.notifier).repairThumbnails(
      onProgress: (done, total) {
        doneNotifier.value = done;
        totalNotifier.value = total;
        if (done >= 3) {
          final elapsed = DateTime.now().difference(startTime);
          final perItem = elapsed.inMilliseconds / done;
          etaNotifier.value = _formatEta(
              Duration(milliseconds: (perItem * (total - done)).round()));
        }
      },
    ).whenComplete(() {
      // 失敗時も必ずダイアログを閉じる
      doneNotifier.dispose();
      totalNotifier.dispose();
      etaNotifier.dispose();
      if (mounted) Navigator.pop(context);
    }).catchError((_) {});
  }

  // ─── 危険な操作 ───

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
    if (mounted) setState(() {}); // 容量表示を再計算
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
      message: '$_itemCount件のアイテム、$_playlistCount件のプレイリスト、'
          '$_tagCount件のタグが完全に失われます。',
      confirmLabel: '完全に削除',
      destructive: true,
    );
    if (!really) return;

    setState(() => _busy = true);
    try {
      await AppBoxes.loopItems.clear();
      await AppBoxes.playlists.clear();
      await AppBoxes.tags.clear();
      // イースターエッグもリセット
      final settingsBox = AppBoxes.settings;
      await settingsBox.delete(SettingsKeys.eeStats);
      await settingsBox.delete(SettingsKeys.eeCassette);
      await settingsBox.delete(SettingsKeys.eeMatrix);

      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);
      ref.invalidate(easterEggProvider);

      _toast(AppSnackBar.success('すべてのデータを削除しました'));
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final isDark = ref.watch(themeProvider);
    final seekStep = ref.watch(seekStepProvider);
    final crossfade = ref.watch(crossfadeProvider);
    final textTheme = Theme.of(context).textTheme;
    final viewPadding = MediaQuery.viewPaddingOf(context);

    return Scaffold(
      appBar: AppBar(title: Text('設定', style: textTheme.displaySmall)),
      body: Stack(
        children: [
          // 説明文はタイトルより一段控えめに（強弱が無いと詰まって見える）
          ListTileTheme.merge(
            titleTextStyle: textTheme.bodyLarge,
            subtitleTextStyle: textTheme.bodySmall,
            child: ListView(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.xl + viewPadding.left,
                AppSpacing.md,
                AppSpacing.xl + viewPadding.right,
                AppSpacing.xxl + viewPadding.bottom),
            children: [
              _LibrarySummary(
                items: _itemCount,
                playlists: _playlistCount,
                tags: _tagCount,
              ),

              _SettingsSection(
                title: '表示',
                children: [
                  SwitchListTile(
                    secondary:
                        Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                    title: const Text('ダークモード'),
                    value: isDark,
                    onChanged: (v) =>
                        ref.read(themeProvider.notifier).value = v,
                  ),
                  // 値が長い（「パーティクル (Particles)」等）ので右寄せせず説明文に出す
                  ListTile(
                    leading: const Icon(Icons.animation),
                    title: const Text('読み込み中の演出'),
                    subtitle: Text(
                        _animationLabel(ref.watch(loadingAnimationProvider))),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showAnimationPicker(context),
                  ),
                  // プレイリスト再生画面のガラス板。ぼかしは GPU 負荷があるので
                  // 重い端末では切れるようにしてある
                  SwitchListTile(
                    secondary: const Icon(Icons.blur_on),
                    title: const Text('再生画面のぼかし'),
                    subtitle: const Text('コントローラーの背景をぼかす。重い端末ではオフに'),
                    value: ref.watch(glassBlurProvider),
                    onChanged: (v) =>
                        ref.read(glassBlurProvider.notifier).value = v,
                  ),
                ],
              ),

              _SettingsSection(
                title: '再生',
                children: [
                  _ValueTile(
                    icon: Icons.forward_10,
                    title: '早送り・巻き戻しの秒数',
                    value: '$seekStep秒',
                    onTap: _pickSeekStep,
                  ),
                  // プレイリストで次曲がプリロード済みのとき、B点/終端の手前から重ねて鳴らす
                  _ValueTile(
                    icon: Icons.multitrack_audio,
                    title: 'クロスフェード',
                    value: _crossfadeLabel(crossfade),
                    onTap: _pickCrossfade,
                  ),
                  // クロスフェード中だけ効く。前後の曲の BPM が解析済みのときに
                  // 次曲の速度を ±8% まで寄せ、交差後に元へ戻す
                  SwitchListTile(
                    secondary: const Icon(Icons.speed),
                    title: const Text('テンポ合わせ'),
                    subtitle: Text(crossfade == 0
                        ? 'クロスフェードをオンにすると使えます'
                        : 'クロスフェード中、次曲の速度を前曲のテンポに寄せる'),
                    value: ref.watch(tempoMatchProvider),
                    onChanged: crossfade == 0
                        ? null
                        : (v) => ref.read(tempoMatchProvider.notifier).value = v,
                  ),
                ],
              ),

              _SettingsSection(
                title: 'ストレージ',
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.sd_storage),
                    title: const Text('オフライン動画を端末に残す'),
                    subtitle: Text(_keepOfflineVideos
                        ? 'アプリを削除するまで残ります'
                        : '容量不足で消えることがあります'),
                    value: _keepOfflineVideos,
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
                      final waiting =
                          snap.connectionState == ConnectionState.waiting;
                      final mb =
                          ((snap.data ?? 0) / 1024 / 1024).toStringAsFixed(1);
                      return _ValueTile(
                        icon: Icons.folder_open,
                        title: 'オフライン動画の容量',
                        value: waiting ? '計算中…' : '$mb MB',
                      );
                    },
                  ),
                  // 波形は 4KB/曲 なので上限は設けない。作り直したいときだけ消す
                  FutureBuilder<(int, int)>(
                    future: WaveformCache.stats(),
                    builder: (_, snap) {
                      final (count, bytes) = snap.data ?? (0, 0);
                      final kb = (bytes / 1024).toStringAsFixed(0);
                      return _ValueTile(
                        icon: Icons.graphic_eq,
                        title: '保存済みの波形',
                        value: snap.hasData ? '$count 曲 · $kb KB' : '計算中…',
                        onTap: count == 0 ? null : _clearWaveformCache,
                        showChevron: count > 0,
                      );
                    },
                  ),
                ],
              ),

              _SettingsSection(
                title: 'バックアップ',
                children: [
                  ListTile(
                    leading: const Icon(Icons.upload_file),
                    title: const Text('バックアップを書き出す'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy ? null : _exportData,
                  ),
                  ListTile(
                    leading: const Icon(Icons.download),
                    title: const Text('バックアップから復元'),
                    subtitle: const Text('今のデータは置き換わります'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy ? null : _importData,
                  ),
                ],
              ),

              _SettingsSection(
                title: 'アプリ情報',
                children: [
                  ListTile(
                    leading: const Icon(Icons.system_update),
                    title: const Text('アップデートを確認'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      UpdateService.checkForUpdate(context);
                      _toast(AppSnackBar.info('最新版を確認中...'));
                    },
                  ),
                  FutureBuilder<PackageInfo>(
                    future: PackageInfo.fromPlatform(),
                    builder: (_, snap) {
                      final version = snap.data?.version ?? '…';
                      final ee = ref.watch(easterEggProvider);
                      return _ValueTile(
                        icon: Icons.info_outline,
                        title: 'バージョン',
                        value: ee.statsUnlocked
                            ? 'v$version (${ee.unlockedCount}/3)'
                            : 'v$version',
                        onTap: _onVersionTap,
                        showChevron: false,
                      );
                    },
                  ),
                ],
              ),

              // 取り返しのつかない操作は、普段の操作から離して最下部にまとめる
              _SettingsSection(
                title: '危険な操作',
                danger: true,
                children: [
                  _DangerTile(
                    icon: Icons.delete_sweep,
                    title: 'オフライン動画をすべて削除',
                    subtitle: '曲の登録やAB区間は残ります',
                    onTap: _busy ? null : _clearAllOfflineVideos,
                  ),
                  _DangerTile(
                    icon: Icons.delete_forever,
                    title: 'すべてのデータを削除',
                    subtitle: '元に戻せません',
                    onTap: _busy ? null : _clearAllData,
                  ),
                ],
              ),

              // 開発者向けは普段は畳んでおく
              Card(
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  leading: const Icon(Icons.code),
                  title: const Text('開発者向け'),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.speed),
                      title: const Text('パフォーマンスオーバーレイ'),
                      subtitle: const Text('FPS・描画負荷を表示'),
                      value: ref.watch(perfOverlayProvider),
                      onChanged: (_) =>
                          ref.read(perfOverlayProvider.notifier).toggle(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          ),
          if (_busy)
            Container(
              color: Colors.black38,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  // ─── 読み込み中のアニメーション ───

  Map<LoadingAnimationType?, String> _getAnimationLabels() {
    final ee = ref.read(easterEggProvider);
    return {
      null: 'ランダム',
      LoadingAnimationType.wave: '波形 (Wave)',
      LoadingAnimationType.mystify: 'ライン (Mystify)',
      LoadingAnimationType.starfield: '星空 (Starfield)',
      LoadingAnimationType.particles: 'パーティクル (Particles)',
      if (ee.cassetteUnlocked)
        LoadingAnimationType.cassette: 'カセット (Cassette)',
      if (ee.matrixUnlocked)
        LoadingAnimationType.matrix: 'マトリックス (Matrix)',
      LoadingAnimationType.off: 'オフ',
    };
  }

  String _animationLabel(LoadingAnimationType? type) =>
      _getAnimationLabels()[type] ?? 'ランダム';

  void _showAnimationPicker(BuildContext context) {
    final labels = _getAnimationLabels();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _AnimPickerSheet(
        labels: labels,
        initial: ref.read(loadingAnimationProvider),
        onSelect: (type) {
          ref.read(loadingAnimationProvider.notifier).set(type);
        },
        onCassetteUnlock: () {
          final unlocked = ref.read(easterEggProvider.notifier).unlockCassette();
          if (unlocked && mounted) {
            // シートを閉じてからSnackBar
            Navigator.pop(ctx);
            _toast(AppSnackBar.success(
                '🎵 隠しアニメーション「カセット」がアンロックされました！'));
          }
        },
      ),
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

/// アニメーションピッカー: プレビュー付きボトムシート
class _AnimPickerSheet extends StatefulWidget {
  final Map<LoadingAnimationType?, String> labels;
  final LoadingAnimationType? initial;
  final ValueChanged<LoadingAnimationType?> onSelect;
  final VoidCallback onCassetteUnlock;

  const _AnimPickerSheet({
    required this.labels,
    required this.initial,
    required this.onSelect,
    required this.onCassetteUnlock,
  });

  @override
  State<_AnimPickerSheet> createState() => _AnimPickerSheetState();
}

class _AnimPickerSheetState extends State<_AnimPickerSheet> {
  late LoadingAnimationType? _selected;
  bool _holdingOff = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
  }

  void _onOffPressStart() {
    setState(() => _holdingOff = true);
    Future.delayed(const Duration(seconds: 5), () {
      if (_holdingOff && mounted) {
        setState(() => _holdingOff = false);
        widget.onCassetteUnlock();
      }
    });
  }

  void _onOffPressEnd() {
    setState(() => _holdingOff = false);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Text('ローディングアニメーション',
                style: textTheme.titleSmall),
          ),
          // プレビュー
          Container(
            height: 160,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppTheme.darkBackground,
              borderRadius: AppRadius.borderMd,
            ),
            child: _selected == LoadingAnimationType.off
                ? Center(
                    child: Text('プレビューなし',
                        style: textTheme.bodySmall!
                            .copyWith(color: Colors.grey)),
                  )
                : LoadingAnimationView(
                    key: ValueKey(_selected),
                    type: _selected,
                  ),
          ),
          const SizedBox(height: AppSpacing.lg),
          // 選択肢
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in widget.labels.entries)
                    _buildTile(entry.key, entry.value),
                  const SizedBox(height: AppSpacing.md),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(LoadingAnimationType? type, String label) {
    final isSelected = type == _selected;
    final isOff = type == LoadingAnimationType.off;

    Widget tile = ListTile(
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: isSelected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(label),
      trailing: isOff && _holdingOff
          ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      onTap: () {
        setState(() => _selected = type);
        widget.onSelect(type);
      },
    );

    if (isOff) {
      tile = GestureDetector(
        onLongPressStart: (_) => _onOffPressStart(),
        onLongPressEnd: (_) => _onOffPressEnd(),
        onLongPressCancel: _onOffPressEnd,
        child: tile,
      );
    }

    return tile;
  }
}

// ============================================================
// 設定画面の部品
// ============================================================

/// 画面上部のライブラリ概要（アイテム・プレイリスト・タグの数）。
/// 以前は「データ管理」カードの中に操作と混ざって置かれていた。
class _LibrarySummary extends StatelessWidget {
  const _LibrarySummary({
    required this.items,
    required this.playlists,
    required this.tags,
  });

  final int items;
  final int playlists;
  final int tags;

  @override
  Widget build(BuildContext context) {
    // Card は左右に lg(12) のマージンを持つので、はみ出さないよう揃える
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
      child: Row(
        children: [
          _stat(context, Icons.music_note, items, 'アイテム'),
          const SizedBox(width: AppSpacing.md),
          _stat(context, Icons.queue_music, playlists, 'プレイリスト'),
          const SizedBox(width: AppSpacing.md),
          _stat(context, Icons.label_outline, tags, 'タグ'),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, IconData icon, int count, String label) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: AppRadius.borderMd,
        ),
        child: Column(
          children: [
            Icon(icon, size: AppIconSizes.s, color: Colors.grey),
            const SizedBox(height: 2),
            Text('$count', style: theme.textTheme.displaySmall),
            Text(label,
                style: theme.textTheme.labelSmall!.copyWith(fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

/// 見出し＋1枚のカードにまとめたセクション。
/// 以前は「外観」だけ1項目1カードで、他と見た目の粒度が揃っていなかった。
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
    this.danger = false,
  });

  final String title;
  final List<Widget> children;

  /// 取り返しのつかない操作のセクション。見出しを赤くする
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerColor = danger ? Colors.red : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
            child: Text(
              title,
              style: theme.textTheme.labelMedium!.copyWith(
                fontWeight: FontWeight.bold,
                color: headerColor,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            shape: danger
                ? RoundedRectangleBorder(
                    borderRadius: AppRadius.borderMd,
                    side: BorderSide(color: Colors.red.withValues(alpha: 0.4)),
                  )
                : null,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 56),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 現在の値を右側に出す行（タップで変更）
class _ValueTile extends StatelessWidget {
  const _ValueTile({
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;

  /// タップで別の画面・選択肢を開く行だけ「›」を出す
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: theme.textTheme.bodyMedium!
                  .copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (onTap != null && showChevron) ...[
            const SizedBox(width: AppSpacing.xs),
            const Icon(Icons.chevron_right),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 取り返しのつかない操作の行（赤）
class _DangerTile extends StatelessWidget {
  const _DangerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.red),
      title: Text(title, style: const TextStyle(color: Colors.red)),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }
}
