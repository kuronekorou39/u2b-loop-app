import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sheets.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';
import '../loop/loop_panel_parts.dart';
import 'more_tile.dart';
import 'player_more_sheet.dart';

/// 単体再生画面の「その他」シート。
/// 音量とループの間は上に 1 行ずつ、書き出し・動画の表示切替・オーディオ出力は
/// 四角いタイル。速度はピル、±N 秒の秒数は長押し。
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
    return AppSheets.popup<void>(context, builder: (_) => sheet);
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
    final gapColor = loop.enabled ? null : AppTheme.muted(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset + AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VolumeSliderRow(),
            // ループの間: B で止まって A に戻るまでの待ち（ループ ON のときだけ動く）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Icon(Icons.hourglass_bottom,
                        size: AppIconSizes.lg, color: gapColor),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Text('ループの間',
                      style: textTheme.bodyMedium?.copyWith(color: gapColor)),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: LoopGapSlider(
                      gapSeconds: loop.gapSeconds,
                      onChanged: loop.enabled
                          ? ref.read(loopProvider.notifier).setGap
                          : (_) {},
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            MoreTileGrid(tiles: [
              MoreTile(
                icon: Icons.file_download_outlined,
                label: loop.hasBothPoints ? '区間を書き出し' : '全体を書き出し',
                corner: Icons.chevron_right,
                enabled: hasSource,
                onTap: () {
                  Navigator.pop(context);
                  widget.onExport();
                },
              ),
              MoreTile(
                icon: _hideVideo
                    ? Icons.videocam_off_outlined
                    : Icons.videocam_outlined,
                label: '動画',
                active: !_hideVideo,
                onTap: () {
                  setState(() => _hideVideo = !_hideVideo);
                  widget.onHideVideoChanged(_hideVideo);
                },
              ),
              MoreTile(icon: deviceIcon, label: '出力', value: deviceLabel),
            ]),
          ],
        ),
      ),
    );
  }
}
