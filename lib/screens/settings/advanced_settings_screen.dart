import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_boxes.dart';
import '../../core/ui/app_dialogs.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../providers/data_provider.dart';
import '../../providers/debug_mode_provider.dart';
import '../../providers/glass_provider.dart';
import '../../providers/perf_overlay_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/settings/hq_audio_log_dialog.dart';
import '../../widgets/settings/settings_parts.dart';
import '../../widgets/settings/stats_dialog.dart';

/// 設定「詳細設定」: 表示 / 再生 / 危険な操作。デバッグモードの間は「デバッグ」の群も出る
class AdvancedSettingsScreen extends ConsumerStatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  ConsumerState<AdvancedSettingsScreen> createState() =>
      _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState
    extends ConsumerState<AdvancedSettingsScreen> {
  bool _busy = false;

  void _toast(AppToastMessage bar) {
    if (mounted) AppToast.instance.show(bar);
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
      ref.invalidate(loopItemsProvider);
      ref.invalidate(playlistsProvider);
      ref.invalidate(tagsProvider);

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
                // ガラス板のぼかしは GPU 負荷があるので、重い端末では切れるようにしてある
                SettingsSwitchRow(
                  icon: Icons.blur_on,
                  title: '画面のぼかし',
                  subtitle: 'ガラス板の背景をぼかす。重い端末ではオフに',
                  value: ref.watch(glassBlurProvider),
                  onChanged: (v) => ref.read(glassBlurProvider.notifier).value = v,
                ),
                SettingsSwitchRow(
                  icon: Icons.image_outlined,
                  title: 'タグのサムネ',
                  value: ref.watch(tagThumbsProvider),
                  onChanged: (v) => ref.read(tagThumbsProvider.notifier).value = v,
                ),
              ],
            ),
            SettingsGroup(
              title: '再生',
              children: [
                // 一体型ストリームの音声は 96kbps。音声専用を別に落として重ねる（HqAudio）。
                // 端末によっては落とせない（403）ことがあるので切れるようにしてある
                SettingsSwitchRow(
                  icon: Icons.high_quality,
                  title: 'YouTube を高音質で再生',
                  subtitle: '音声専用ストリーム（128kbps 前後）を別に取得して重ねる。'
                      'オフだと一体型の 96kbps',
                  value: ref.watch(hqAudioProvider),
                  onChanged: (v) => ref.read(hqAudioProvider.notifier).value = v,
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
            // バージョン行を 5 回押した端末にだけ出す（ふつうの人が触らないもの）
            if (ref.watch(debugModeProvider))
              SettingsGroup(
                title: 'デバッグ',
                children: [
                  // GitHub のプレリリース（-beta のタグ）も更新として知らせる
                  SettingsSwitchRow(
                    icon: Icons.science_outlined,
                    title: 'テスト版も受け取る',
                    value: ref.watch(betaUpdatesProvider),
                    onChanged: (v) =>
                        ref.read(betaUpdatesProvider.notifier).value = v,
                  ),
                  SettingsSwitchRow(
                    icon: Icons.speed,
                    title: 'パフォーマンスオーバーレイ',
                    value: ref.watch(perfOverlayProvider),
                    onChanged: (_) =>
                        ref.read(perfOverlayProvider.notifier).toggle(),
                  ),
                  // 高音質が付かない時に、端末だけで原因を追えるように
                  SettingsRow(
                    icon: Icons.receipt_long,
                    title: '高音質のログ',
                    onTap: () => HqAudioLogDialog.show(context),
                  ),
                  SettingsRow(
                    icon: Icons.analytics_outlined,
                    title: '統計',
                    onTap: () => StatsDialog.show(context),
                  ),
                  SettingsRow(
                    icon: Icons.logout,
                    title: 'デバッグモードを終了',
                    showChevron: false,
                    onTap: () =>
                        ref.read(debugModeProvider.notifier).disable(),
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

