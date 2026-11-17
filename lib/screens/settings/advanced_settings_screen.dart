import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/glass_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「表示・再生」: 画面のぼかし・タグのサムネ・高音質。
/// 消す操作は「保存データ」、デバッグはトップの別のボタン
class AdvancedSettingsScreen extends ConsumerWidget {
  const AdvancedSettingsScreen({super.key});

  /// ページの名前（トップのボタンと同じ）
  static const title = '表示・再生';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPage(
      title: title,
      children: [
        SettingsGroup(
          title: '表示',
          children: [
            // ガラス板のぼかしは GPU 負荷があるので、重い端末では切れるようにしてある
            SettingsSwitchRow(
              icon: Icons.blur_on,
              title: '画面のぼかし',
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
            // 一体型ストリームの音声は 96kbps。音声専用（128kbps 前後）を別に落として重ねる（HqAudio）。
            // 端末によっては落とせない（403）ことがあるので切れるようにしてある
            SettingsSwitchRow(
              icon: Icons.high_quality,
              title: 'YouTube を高音質で再生',
              value: ref.watch(hqAudioProvider),
              onChanged: (v) => ref.read(hqAudioProvider.notifier).value = v,
            ),
          ],
        ),
      ],
    );
  }
}
