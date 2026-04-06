import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/player_provider.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key});

  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _seekSteps = [1, 5, 10, 30];

  static const _rewindIcons = <int, IconData>{
    1: Icons.replay,
    5: Icons.replay_5,
    10: Icons.replay_10,
    30: Icons.replay_30,
  };
  static const _forwardIcons = <int, IconData>{
    1: Icons.forward,
    5: Icons.forward_5,
    10: Icons.forward_10,
    30: Icons.forward_30,
  };

  void _showStepMenu(
      BuildContext context, Offset position, WidgetRef ref) async {
    final currentStep = ref.read(seekStepProvider);
    final result = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx - 40, position.dy - 160, position.dx + 40, position.dy),
      items: _seekSteps
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
      ref.read(seekStepProvider.notifier).state = result;
    }
  }

  void _showVolumeMenu(
      BuildContext context, Offset position, Player player, WidgetRef ref) async {
    await showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _VolumeDialog(player: player, anchor: position, ref: ref),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final volume = ref.watch(volumeProvider).valueOrNull ?? 100.0;
    final rate = ref.watch(rateProvider).valueOrNull ?? 1.0;
    final player = ref.read(playerProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final seekStep = ref.watch(seekStepProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Rewind: tap=seek, long press=set step
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) =>
                    _showStepMenu(context, details.globalPosition, ref)
                : null,
            child: IconButton(
              icon: Icon(_rewindIcons[seekStep] ?? Icons.replay_5),
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
          IconButton(
            icon: Icon(
              playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
            ),
            iconSize: 48,
            onPressed: hasSource ? () => player.playOrPause() : null,
            color: Theme.of(context).colorScheme.primary,
          ),
          // Forward: tap=seek, long press=set step
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) =>
                    _showStepMenu(context, details.globalPosition, ref)
                : null,
            child: IconButton(
              icon: Icon(_forwardIcons[seekStep] ?? Icons.forward_5),
              onPressed: hasSource
                  ? () {
                      final pos = player.state.position;
                      player.seek(pos + Duration(seconds: seekStep));
                    }
                  : null,
            ),
          ),
          // Volume: tap=mute toggle (with memory), long press=slider
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) => _showVolumeMenu(
                    context, details.globalPosition, player, ref)
                : null,
            child: IconButton(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(volume > 0 ? Icons.volume_up : Icons.volume_off),
                  if (volume < 100)
                    Positioned(
                      right: -6,
                      bottom: -8,
                      child: Text(
                        '${volume.round()}',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                          color: volume > 0
                              ? Colors.grey.shade400
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
                        player.setVolume(0);
                      } else {
                        // Unmute: restore previous volume
                        final prev = ref.read(previousVolumeProvider);
                        player.setVolume(prev > 0 ? prev : 100.0);
                      }
                    }
                  : null,
            ),
          ),
          PopupMenuButton<double>(
            initialValue: rate,
            onSelected: (speed) => player.setRate(speed),
            enabled: hasSource,
            itemBuilder: (context) => _speeds
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
                  color: hasSource ? Colors.grey : Colors.grey.shade800,
                ),
                borderRadius: AppRadius.borderSm,
              ),
              child: Text(
                '${rate}x',
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  color: hasSource ? null : Colors.grey.shade600,
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
  final Player player;
  final Offset anchor;
  final WidgetRef ref;
  const _VolumeDialog(
      {required this.player, required this.anchor, required this.ref});

  @override
  State<_VolumeDialog> createState() => _VolumeDialogState();
}

class _VolumeDialogState extends State<_VolumeDialog> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.player.state.volume;
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
                        widget.ref
                            .read(previousVolumeProvider.notifier)
                            .state = _volume;
                        widget.player.setVolume(0);
                        setState(() => _volume = 0);
                      } else {
                        final prev =
                            widget.ref.read(previousVolumeProvider);
                        final restored = prev > 0 ? prev : 100.0;
                        widget.player.setVolume(restored);
                        setState(() => _volume = restored);
                      }
                    },
                    child: Icon(
                      _volume > 0 ? Icons.volume_up : Icons.volume_off,
                      size: 20,
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7),
                      ),
                      child: Slider(
                        value: _volume.clamp(0, 100),
                        min: 0,
                        max: 100,
                        onChanged: (v) {
                          widget.player.setVolume(v);
                          setState(() => _volume = v);
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
