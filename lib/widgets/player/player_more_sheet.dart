import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/app_sheets.dart';
import '../../core/utils/rate_label.dart';
import '../../providers/player_provider.dart';
import '../../screens/settings/dj_mix_settings_screen.dart';
import 'more_tile.dart';
import 'player_controls.dart';
import 'volume_slider.dart';

/// プレイリスト再生画面の「その他」メニュー（向きに関係なく真ん中のポップアップ）。
/// 下部コントローラーから外した補助機能を四角いタイルで並べ、音量は一番上に 1 行。
/// 1 行目は別の画面を開くもの（AB区間・DJ ミックス・保存。右上に ›）、
/// 2 行目はその場で変わるもの（速度はプルダウン、音量正規化・動画はオンオフで緑に光る）。
/// 1 番だけはコントローラーのボタン（長押しで手直し・自動に戻す）なのでここには無い。
/// 波形の表示切替はシークバー右下のボタン。
///
/// 画面側の状態（動画非表示）は初期値とコールバックで受け取り、
/// シート内では自前のコピーを持って即時に反映する。
class PlayerMoreSheet extends ConsumerStatefulWidget {
  const PlayerMoreSheet({
    super.key,
    required this.onToggleVolumeNorm,
    required this.onEditAb,
    required this.onDjMix,
    this.onSave,
    required this.hideVideo,
    required this.onHideVideoChanged,
  });

  final VoidCallback onToggleVolumeNorm;

  /// 「AB区間」。このシートを閉じてから呼ばれる
  final VoidCallback onEditAb;

  /// 「DJ ミックス」。このシートを閉じてから呼ばれる（呼び先で DjMixSheet を開く）
  final VoidCallback onDjMix;

  /// 「保存」（アプリ内に保存 / 端末に書き出し）。このシートを閉じてから呼ばれる
  final VoidCallback? onSave;
  final bool hideVideo;
  final ValueChanged<bool> onHideVideoChanged;

  /// 速度の候補は全画面・単体のピルと同じ（以前は 6 段で、0.25x のとき何も選ばれていない表示だった）
  static const speeds = PlayerControls.speeds;

  static Future<void> show(BuildContext context, PlayerMoreSheet sheet) {
    return AppSheets.popup<void>(context, builder: (_) => sheet);
  }

  @override
  ConsumerState<PlayerMoreSheet> createState() => _PlayerMoreSheetState();
}

class _PlayerMoreSheetState extends ConsumerState<PlayerMoreSheet> {
  late bool _hideVideo = widget.hideVideo;

  @override
  Widget build(BuildContext context) {
    final hasSource = ref.watch(videoSourceProvider) != null;
    final volumeNorm = ref.watch(volumeNormProvider);
    final rate = ref.watch(rateProvider).valueOrNull ?? 1.0;
    final crossfade = ref.watch(crossfadeProvider);

    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset + AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VolumeSliderRow(),
            const SizedBox(height: AppSpacing.md),
            // 1 行目は別の画面を開くもの（›）、2 行目はその場で変わるもの
            MoreTileGrid(tiles: [
              MoreTile(
                icon: Icons.tune,
                label: 'AB区間',
                corner: Icons.chevron_right,
                onTap: () {
                  Navigator.pop(context);
                  widget.onEditAb();
                },
              ),
              MoreTile(
                icon: Icons.multitrack_audio,
                label: 'DJ ミックス',
                value: DjMixSettingsScreen.crossfadeLabel(crossfade),
                corner: Icons.chevron_right,
                onTap: () {
                  Navigator.pop(context);
                  widget.onDjMix();
                },
              ),
              if (widget.onSave != null)
                MoreTile(
                  icon: Icons.download_outlined,
                  label: '保存',
                  corner: Icons.chevron_right,
                  onTap: () {
                    Navigator.pop(context);
                    widget.onSave!();
                  },
                ),
              SpeedTile(
                rate: rate,
                enabled: hasSource,
                onChanged: (s) => ref.read(playerProvider).setRate(s),
              ),
              MoreTile(
                icon: Icons.equalizer,
                label: '音量正規化',
                active: volumeNorm,
                onTap: widget.onToggleVolumeNorm,
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
            ]),
          ],
        ),
      ),
    );
  }
}

/// 速度のタイル。今の値を出し、押すとその場に候補のメニュー
class SpeedTile extends StatelessWidget {
  const SpeedTile({
    super.key,
    required this.rate,
    required this.onChanged,
    this.enabled = true,
  });

  final double rate;
  final ValueChanged<double> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => PickerTile<double>(
        icon: Icons.speed,
        label: '速度',
        values: PlayerMoreSheet.speeds,
        selected: PlayerMoreSheet.speeds
                .where((s) => sameRate(s, rate))
                .firstOrNull ??
            rate,
        labelOf: rateLabel,
        enabled: enabled,
        onPicked: onChanged,
      );
}

/// 音量の行: ミュート切替（前の音量を覚える）+ スライダー + %。
/// プレイリスト・単体の両方の「その他」シートで使う。
/// スライダーを動かしている間は自前の値で即時に描き、離したらプロバイダの値に戻る
class VolumeSliderRow extends ConsumerStatefulWidget {
  const VolumeSliderRow({super.key});

  @override
  ConsumerState<VolumeSliderRow> createState() => _VolumeSliderRowState();
}

class _VolumeSliderRowState extends ConsumerState<VolumeSliderRow> {

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final hasSource = ref.watch(videoSourceProvider) != null;
    final volume = ref.watch(userVolumeProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Row(
        children: [
          IconButton(
            icon: Icon(volume > 0 ? Icons.volume_up : Icons.volume_off),
            tooltip: volume > 0 ? 'ミュート' : 'ミュート解除',
            onPressed: hasSource
                ? () {
                    double next;
                    if (volume > 0) {
                      ref.read(previousVolumeProvider.notifier).state = volume;
                      next = 0;
                    } else {
                      final prev = ref.read(previousVolumeProvider);
                      next = prev > 0 ? prev : 100.0;
                    }
                    ref.read(userVolumeProvider.notifier).value = next;
                  }
                : null,
          ),
          Expanded(
            child: VolumeSlider(
              value: volume,
              onChanged: hasSource
                  ? (v) => ref.read(userVolumeProvider.notifier).value = v
                  : null,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${volume.round()}%',
              style: textTheme.labelSmall,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
