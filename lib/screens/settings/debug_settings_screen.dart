import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/debug_mode_provider.dart';
import '../../providers/perf_overlay_provider.dart';
import '../../widgets/settings/hq_audio_log_dialog.dart';
import '../../widgets/settings/settings_parts.dart';
import '../../widgets/settings/stats_dialog.dart';

/// 設定「デバッグ」。アップデートの札を 5 回押した端末にだけ、設定のトップにボタンが出る
class DebugSettingsScreen extends ConsumerWidget {
  const DebugSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPage(
      title: 'デバッグ',
      children: [
        SettingsGroup(
          children: [
            // GitHub のプレリリース（-beta のタグ）も更新として知らせる
            SettingsSwitchRow(
              icon: Icons.science_outlined,
              title: 'テスト版も受け取る',
              value: ref.watch(betaUpdatesProvider),
              onChanged: (v) => ref.read(betaUpdatesProvider.notifier).value = v,
            ),
            SettingsSwitchRow(
              icon: Icons.speed,
              title: 'パフォーマンスオーバーレイ',
              value: ref.watch(perfOverlayProvider),
              onChanged: (_) => ref.read(perfOverlayProvider.notifier).toggle(),
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
          ],
        ),
        SettingsGroup(
          children: [
            // 終了すると中の設定も切れ、トップのボタンも消える（このページも閉じる）
            SettingsRow(
              icon: Icons.logout,
              title: 'デバッグモードを終了',
              showChevron: false,
              onTap: () {
                ref.read(debugModeProvider.notifier).disable();
                Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
      ],
    );
  }
}
