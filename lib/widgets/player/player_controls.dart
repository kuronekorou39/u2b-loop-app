import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';
import 'player_glass_bar.dart';
import 'volume_slider.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key, this.prevTrack, this.nextTrack});

  /// 再生ボタンの外側に置く「前の曲」「次の曲」（全画面のプレイリスト）
  final Widget? prevTrack;
  final Widget? nextTrack;

  static const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  static const _rewindIcons = <int, IconData>{
    5: Icons.replay_5,
    10: Icons.replay_10,
    30: Icons.replay_30,
  };
  static const _forwardIcons = <int, IconData>{
    5: Icons.forward_5,
    10: Icons.forward_10,
    30: Icons.forward_30,
  };

  /// ±N 秒のアイコン（5/10/30 以外は 5 のアイコンで代用）
  static IconData rewindIcon(int step) => _rewindIcons[step] ?? Icons.replay_5;
  static IconData forwardIcon(int step) =>
      _forwardIcons[step] ?? Icons.forward_5;

  /// ±N 秒の秒数を選ぶメニュー（長押しで出す）。単体再生のガラス板コントローラーとも共用
  static Future<void> showStepMenu(
      BuildContext context, Offset position, WidgetRef ref) async {
    final currentStep = ref.read(seekStepProvider);
    final result = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx - 40, position.dy - 160, position.dx + 40, position.dy),
      items: SeekStepNotifier.options
          .map((s) => PopupMenuItem(
                value: s,
                height: 36,
                child: Text(
                  '${s}s',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: s == currentStep ? FontWeight.bold : null,
                    color: s == currentStep
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ))
          .toList(),
    );
    if (result != null) {
      ref.read(seekStepProvider.notifier).value = result;
    }
  }

  void _showVolumeMenu(BuildContext context, Offset position, WidgetRef ref) async {
    await showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _VolumeDialog(
        initial: ref.read(userVolumeProvider),
        onChanged: (v) => ref.read(userVolumeProvider.notifier).value = v,
        anchor: position,
        previousVolume: ref.read(previousVolumeProvider),
        onPreviousVolumeChanged: (v) =>
            ref.read(previousVolumeProvider.notifier).state = v,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final volume = ref.watch(userVolumeProvider);
    final rate = ref.watch(rateProvider).valueOrNull ?? 1.0;
    final player = ref.read(playerProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final seekStep = ref.watch(seekStepProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // オーディオデバイス表示
          Consumer(builder: (_, ref, _) {
            final device = ref.watch(audioDeviceProvider);
            final icon = switch (device) {
              'bluetooth' => Icons.bluetooth_audio,
              'headphones' => Icons.headphones,
              _ => Icons.speaker,
            };
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(icon, size: 16, color: AppTheme.muted(context)),
            );
          }),
          // 最初から: A地点 or 先頭にシーク
          IconButton(
            // 前の曲（skip_previous）と見分けられるように、単体再生の「先頭へ」と同じ形
            icon: const Icon(Icons.first_page_rounded),
            tooltip: 'A / 先頭へ',
            iconSize: 22,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.all(8),
            onPressed: hasSource
                ? () {
                    final loop = ref.read(loopProvider);
                    final target = (loop.enabled && loop.hasA)
                        ? loop.pointA!
                        : Duration.zero;
                    player.seek(target);
                  }
                : null,
          ),
          ?prevTrack,
          // Rewind: tap=seek, long press=set step
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) =>
                    showStepMenu(context, details.globalPosition, ref)
                : null,
            child: IconButton(
              icon: Icon(rewindIcon(seekStep)),
              onPressed: hasSource
                  ? () {
                      final pos = player.state.position;
                      final target = pos - Duration(seconds: seekStep);
                      player.seek(
                          target < Duration.zero ? Duration.zero : target);
                    }
                  : null,
            ),
          ),
          // 再生ボタンは縦・横の画面と同じ緑の丸
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: BigPlayButton(
              playing: playing,
              enabled: hasSource,
              size: 48,
              onTap: () => player.playOrPause(),
            ),
          ),
          // Forward: tap=seek, long press=set step
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) =>
                    showStepMenu(context, details.globalPosition, ref)
                : null,
            child: IconButton(
              icon: Icon(forwardIcon(seekStep)),
              onPressed: hasSource
                  ? () {
                      final pos = player.state.position;
                      player.seek(pos + Duration(seconds: seekStep));
                    }
                  : null,
            ),
          ),
          ?nextTrack,
          // Volume: tap=mute toggle (with memory), long press=slider
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) =>
                    _showVolumeMenu(context, details.globalPosition, ref)
                : null,
            child: IconButton(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(volume > 0 ? Icons.volume_up : Icons.volume_off),
                  if (volume.round() != 100)
                    Positioned(
                      right: -6,
                      bottom: -8,
                      child: Text(
                        '${volume.round()}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: volume > 0
                              ? AppTheme.muted(context, alpha: 0.7)
                              : Colors.red.shade300,
                        ),
                      ),
                    ),
                ],
              ),
              onPressed: hasSource
                  ? () {
                      if (volume > 0) {
                        // Mute: save current volume
                        ref.read(previousVolumeProvider.notifier).state =
                            volume;
                        ref.read(userVolumeProvider.notifier).value = 0;
                      } else {
                        // Unmute: restore previous volume
                        final prev = ref.read(previousVolumeProvider);
                        ref.read(userVolumeProvider.notifier).value =
                            prev > 0 ? prev : 100.0;
                      }
                    }
                  : null,
            ),
          ),
          PopupMenuButton<double>(
            initialValue: rate,
            onSelected: (speed) => player.setRate(speed),
            enabled: hasSource,
            itemBuilder: (context) => speeds
                .map(
                  (s) => PopupMenuItem(
                    value: s,
                    child: Text(
                      '${s}x',
                      style: TextStyle(
                        fontWeight:
                            s == rate ? FontWeight.bold : FontWeight.normal,
                        color: s == rate
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                  ),
                )
                .toList(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(
                  color: AppTheme.muted(context, alpha: hasSource ? 0.55 : 0.2),
                ),
                borderRadius: AppRadius.borderSm,
              ),
              child: Text(
                '${rate}x',
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  color: hasSource ? null : AppTheme.muted(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Volume slider dialog shown near the anchor position
class _VolumeDialog extends StatefulWidget {
  final double initial;
  final ValueChanged<double> onChanged;
  final Offset anchor;
  final double previousVolume;
  final ValueChanged<double> onPreviousVolumeChanged;
  const _VolumeDialog({
    required this.initial,
    required this.onChanged,
    required this.anchor,
    required this.previousVolume,
    required this.onPreviousVolumeChanged,
  });

  @override
  State<_VolumeDialog> createState() => _VolumeDialogState();
}

class _VolumeDialogState extends State<_VolumeDialog> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(onTap: () => Navigator.pop(context)),
        ),
        Positioned(
          left: (widget.anchor.dx - 100)
              .clamp(8.0, MediaQuery.of(context).size.width - 208),
          top: widget.anchor.dy - 60,
          child: Material(
            elevation: 8,
            borderRadius: AppRadius.borderMd,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () {
                      if (_volume > 0) {
                        widget.onPreviousVolumeChanged(_volume);
                        widget.onChanged(0);
                        setState(() => _volume = 0);
                      } else {
                        final restored =
                            widget.previousVolume > 0 ? widget.previousVolume : 100.0;
                        widget.onChanged(restored);
                        setState(() => _volume = restored);
                      }
                    },
                    child: Icon(
                      _volume > 0 ? Icons.volume_up : Icons.volume_off,
                      size: 20,
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7),
                      ),
                      child: VolumeSlider(
                        value: _volume,
                        onChanged: (v) {
                          widget.onChanged(v);
                          // 100% への吸い付きは保存側で決まる
                          setState(() => _volume =
                              (v - 100).abs() < 4 ? 100 : v);
                        },
                      ),
                    ),
                  ),
                  Text('${_volume.round()}%',
                      style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
