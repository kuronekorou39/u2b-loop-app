import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';
import '../loop/loop_panel_parts.dart';
import 'player_more_sheet.dart';

/// 単体再生画面の「その他」シート。
/// 下部コントローラーから外した補助機能（音量・ループの間・書き出し・動画の表示切替・
/// オーディオ出力の確認）をまとめる。速度はピル、±N 秒の秒数は長押し。
class SingleMoreSheet extends ConsumerStatefulWidget {
  const SingleMoreSheet({
    super.key,
    required this.onExport,
    required this.hideVideo,
    required this.onHideVideoChanged,
  });

  /// 書き出し（区間があれば区間、無ければ全体）
  final VoidCallback onExport;
  final bool hideVideo;
  final ValueChanged<bool> onHideVideoChanged;

  static Future<void> show(BuildContext context, SingleMoreSheet sheet) {
    return showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => sheet,
    );
  }

  @override
  ConsumerState<SingleMoreSheet> createState() => _SingleMoreSheetState();
}

class _SingleMoreSheetState extends ConsumerState<SingleMoreSheet> {
  late bool _hideVideo = widget.hideVideo;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final hasSource = ref.watch(videoSourceProvider) != null;
    final loop = ref.watch(loopProvider);
    final device = ref.watch(audioDeviceProvider);
    final (deviceIcon, deviceLabel) = switch (device) {
      'bluetooth' => (Icons.bluetooth_audio, 'Bluetooth'),
      'headphones' => (Icons.headphones, 'ヘッドホン'),
      _ => (Icons.speaker, 'スピーカー'),
    };
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset + AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VolumeSliderRow(),
            // ループの間: B で止まって A に戻るまでの待ち
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, 0),
              child: Row(
                children: [
                  Icon(Icons.hourglass_bottom,
                      size: AppIconSizes.lg,
                      color: loop.enabled ? null : AppTheme.muted(context)),
                  const SizedBox(width: AppSpacing.xl),
                  Text('ループの間', style: textTheme.bodyLarge),
                  const SizedBox(width: AppSpacing.md),
                  Text(
                    loop.enabled ? 'B で止まって A に戻るまでの待ち' : 'ループ ON のとき使えます',
                    style: textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl + 36, 0, AppSpacing.xl, 0),
              child: LoopGapSlider(
                gapSeconds: loop.gapSeconds,
                onChanged: loop.enabled
                    ? ref.read(loopProvider.notifier).setGap
                    : (_) {},
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: Text(loop.hasBothPoints ? '区間を書き出し' : '全体を書き出し'),
              subtitle: Text(loop.hasBothPoints
                  ? 'A–B の範囲を動画や音声として保存'
                  : '動画や音声として保存'),
              trailing: const Icon(Icons.chevron_right),
              enabled: hasSource,
              onTap: () {
                Navigator.pop(context);
                widget.onExport();
              },
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.videocam_outlined),
              title: const Text('動画を表示'),
              subtitle: const Text('オフにすると波形と区間を広く使える'),
              value: !_hideVideo,
              onChanged: (v) {
                setState(() => _hideVideo = !v);
                widget.onHideVideoChanged(!v);
              },
            ),
            ListTile(
              leading: Icon(deviceIcon),
              title: const Text('オーディオ出力'),
              subtitle: Text(deviceLabel),
            ),
          ],
        ),
      ),
    );
  }
}
