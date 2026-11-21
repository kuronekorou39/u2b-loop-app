import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/glass_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/settings/settings_parts.dart';

/// 設定「表示・再生」: すりガラス効果・タグのサムネ・高音質・音量の正規化。
/// 消す操作は「データ」、デバッグはトップの別のボタン。横画面は群を左右に並べる
class AdvancedSettingsScreen extends ConsumerWidget {
  const AdvancedSettingsScreen({super.key});

  /// ページの名前（トップのボタンと同じ）
  static const title = '表示・再生';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = SettingsGroup(
      title: '表示',
      children: [
        // 再生画面の操作の板・ミニプレイヤー・タブなどの板の後ろをすりガラスのようにぼかす。
        // GPU 負荷があるので、重い端末では切れるようにしてある（切ると半透明の板だけ）。
        // 以前の名前「画面のぼかし」は何のことか分からなかった
        SettingsSwitchRow(
          icon: Icons.blur_on,
          title: 'すりガラス効果',
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
    );
    final playback = SettingsGroup(
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
        // 曲ごとに測った大きさで音量をそろえる（Loudness）。1 曲ずつ聴くときにも効くので、
        // DJ ミックスではなくここ。再生画面の「その他」の「音量正規化」と同じ設定
        // （ここで切り替えたときは、次に曲を開いたときから効く）
        SettingsSwitchRow(
          icon: Icons.equalizer,
          title: '音量の正規化',
          value: ref.watch(volumeNormProvider),
          onChanged: (v) => ref.read(volumeNormProvider.notifier).value = v,
        ),
      ],
    );
    return SettingsPage(
      title: title,
      wideColumns: [
        [display],
        [playback],
      ],
      children: [display, playback],
    );
  }
}
