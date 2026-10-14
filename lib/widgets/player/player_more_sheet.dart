import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';
import '../../screens/settings/dj_mix_settings_screen.dart';
import 'player_controls.dart';

/// プレイリスト再生画面の「その他」シート。
/// 下部コントローラーから外した補助機能（1番だけ・AB区間・音量正規化・DJ ミックス・速度・音量・
/// 動画の表示切替）をまとめる。波形の表示切替はシークバー右下のボタン。
///
/// 画面側の状態（動画非表示）は初期値とコールバックで受け取り、
/// シート内では自前のコピーを持って即時に反映する。
class PlayerMoreSheet extends ConsumerStatefulWidget {
  const PlayerMoreSheet({
    super.key,
    required this.firstVerseMode,
    required this.onToggleFirstVerse,
    required this.onToggleVolumeNorm,
    required this.onEditAb,
    required this.onDjMix,
    required this.hideVideo,
    required this.onHideVideoChanged,
  });

  final bool firstVerseMode;
  final VoidCallback onToggleFirstVerse;
  final VoidCallback onToggleVolumeNorm;
  final VoidCallback onEditAb;

  /// 「DJ ミックス」の行。このシートを閉じてから呼ばれる（呼び先で DjMixSheet を開く）
  final VoidCallback onDjMix;
  final bool hideVideo;
  final ValueChanged<bool> onHideVideoChanged;

  /// 速度の候補は全画面・単体のピルと同じ（以前は 6 段で、0.25x のとき何も選ばれていない表示だった）
  static const speeds = PlayerControls.speeds;

  static Future<void> show(BuildContext context, PlayerMoreSheet sheet) {
    return showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => sheet,
    );
  }

  @override
  ConsumerState<PlayerMoreSheet> createState() => _PlayerMoreSheetState();
}

class _PlayerMoreSheetState extends ConsumerState<PlayerMoreSheet> {
  late bool _firstVerse = widget.firstVerseMode;
  late bool _hideVideo = widget.hideVideo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final player = ref.read(playerProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final volumeNorm = ref.watch(volumeNormProvider);
    final rate = ref.watch(rateProvider).valueOrNull ?? 1.0;
    final loop = ref.watch(loopProvider);

    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: bottomInset + AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.looks_one_outlined),
              title: const Text('1番だけ'),
              subtitle: const Text('1番が終わるあたりで次の曲へ'),
              value: _firstVerse,
              onChanged: (v) {
                setState(() => _firstVerse = v);
                widget.onToggleFirstVerse();
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.equalizer),
              title: const Text('音量正規化'),
              subtitle: const Text('波形から曲ごとの音量差をならす'),
              value: volumeNorm,
              onChanged: (_) => widget.onToggleVolumeNorm(),
            ),
            ListTile(
              leading: Icon(
                Icons.tune,
                color: loop.hasBothPoints ? AppTheme.accentGreen : null,
              ),
              title: const Text('AB区間を編集'),
              subtitle: Text(loop.hasBothPoints ? 'この曲の再生範囲を指定中' : '再生範囲を指定する'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                widget.onEditAb();
              },
            ),
            // 聴きながら変えたい DJ の設定。設定画面と同じ値を別のシートで
            ListTile(
              leading: Icon(
                Icons.multitrack_audio,
                color: ref.watch(crossfadeProvider) > 0
                    ? AppTheme.accentGreen
                    : null,
              ),
              title: const Text('DJ ミックス'),
              subtitle: Text(DjMixSettingsScreen.summary(ref),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                widget.onDjMix();
              },
            ),
            const Divider(),
            // 速度
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, 0),
              child: Row(
                children: [
                  const Icon(Icons.speed, size: AppIconSizes.lg),
                  const SizedBox(width: AppSpacing.xl),
                  Text('速度', style: textTheme.bodyLarge),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xs),
              child: Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final s in PlayerMoreSheet.speeds)
                    ChoiceChip(
                      label: Text('${s}x'),
                      selected: s == rate,
                      onSelected: hasSource ? (_) => player.setRate(s) : null,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            const VolumeSliderRow(),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.videocam_outlined),
              title: const Text('動画を表示'),
              subtitle: const Text('オフにすると曲リストを広く使える'),
              value: !_hideVideo,
              onChanged: (v) {
                setState(() => _hideVideo = !v);
                widget.onHideVideoChanged(!v);
              },
            ),
          ],
        ),
      ),
    );
  }
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
  double? _volume;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final player = ref.read(playerProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final volume =
        _volume ?? ref.watch(volumeProvider).valueOrNull ?? player.state.volume;

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
                    player.setVolume(next);
                    setState(() => _volume = next);
                  }
                : null,
          ),
          Expanded(
            child: Slider(
              value: volume.clamp(0, 100),
              min: 0,
              max: 100,
              onChanged: hasSource
                  ? (v) {
                      player.setVolume(v);
                      setState(() => _volume = v);
                    }
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
