import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_boxes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../providers/data_provider.dart';
import '../../providers/easter_egg_provider.dart';
import '../../providers/glass_provider.dart';
import '../../providers/loading_animation_provider.dart';
import '../../widgets/loading_animations/loading_animation.dart';
import '../../widgets/loading_animations/loading_animation_widget.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「詳細設定」: 表示 / 危険な操作 / 開発者向け（ふだん触らないもの）
class AdvancedSettingsScreen extends ConsumerStatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  ConsumerState<AdvancedSettingsScreen> createState() =>
      _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState
    extends ConsumerState<AdvancedSettingsScreen> {
  bool _busy = false;

  void _toast(SnackBar bar) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(bar);
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

  void _showAnimationPicker() {
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SettingsPage(
          title: '詳細設定',
          children: [
            SettingsGroup(
              title: '表示',
              children: [
                // 値が長い（「パーティクル (Particles)」等）ので説明文に出す
                SettingsRow(
                  icon: Icons.animation,
                  title: '読み込み中の演出',
                  subtitle: _animationLabel(ref.watch(loadingAnimationProvider)),
                  onTap: _showAnimationPicker,
                ),
                // ガラス板のぼかしは GPU 負荷があるので、重い端末では切れるようにしてある
                SettingsSwitchRow(
                  icon: Icons.blur_on,
                  title: '画面のぼかし',
                  subtitle: 'ガラス板の背景をぼかす。重い端末ではオフに',
                  value: ref.watch(glassBlurProvider),
                  onChanged: (v) => ref.read(glassBlurProvider.notifier).value = v,
                ),
              ],
            ),
            // 取り返しのつかない操作は、普段の操作から離してまとめる
            SettingsGroup(
              title: '危険な操作',
              children: [
                SettingsRow(
                  icon: Icons.delete_sweep,
                  title: 'オフライン動画をすべて削除',
                  subtitle: '曲の登録やAB区間は残ります',
                  danger: true,
                  showChevron: false,
                  onTap: _busy ? null : _clearAllOfflineVideos,
                ),
                SettingsRow(
                  icon: Icons.delete_forever,
                  title: 'すべてのデータを削除',
                  subtitle: '元に戻せません',
                  danger: true,
                  showChevron: false,
                  onTap: _busy ? null : _clearAllData,
                ),
              ],
            ),
            SettingsGroup(
              title: '開発者向け',
              children: [
                SettingsSwitchRow(
                  icon: Icons.speed,
                  title: 'パフォーマンスオーバーレイ',
                  subtitle: 'FPS・描画負荷を表示',
                  value: ref.watch(perfOverlayProvider),
                  onChanged: (_) =>
                      ref.read(perfOverlayProvider.notifier).toggle(),
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
                            .copyWith(color: AppTheme.muted(context))),
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
