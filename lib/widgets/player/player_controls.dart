import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../../providers/player_provider.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key});

  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _seekSteps = [1, 5, 10, 30];

  void _showSeekMenu(
      BuildContext context, Offset position, Player player, bool rewind) async {
    final result = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx - 40, position.dy - 160, position.dx + 40, position.dy),
      items: _seekSteps
          .map((s) => PopupMenuItem(
                value: s,
                height: 36,
                child: Text('${rewind ? "-" : "+"}${s}s',
                    style: const TextStyle(fontSize: 13)),
              ))
          .toList(),
    );
    if (result != null) {
      final pos = player.state.position;
      if (rewind) {
        final target = pos - Duration(seconds: result);
        player.seek(target < Duration.zero ? Duration.zero : target);
      } else {
        player.seek(pos + Duration(seconds: result));
      }
    }
  }

  void _showVolumeMenu(
      BuildContext context, Offset position, Player player) async {
    await showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _VolumeDialog(player: player, anchor: position),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final volume = ref.watch(volumeProvider).valueOrNull ?? 100.0;
    final rate = ref.watch(rateProvider).valueOrNull ?? 1.0;
    final player = ref.read(playerProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Rewind: tap=5s, long press=choose
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) => _showSeekMenu(
                    context, details.globalPosition, player, true)
                : null,
            child: IconButton(
              icon: const Icon(Icons.replay_5),
              onPressed: hasSource
                  ? () {
                      final pos = player.state.position;
                      final target = pos - const Duration(seconds: 5);
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
          // Forward: tap=5s, long press=choose
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) => _showSeekMenu(
                    context, details.globalPosition, player, false)
                : null,
            child: IconButton(
              icon: const Icon(Icons.forward_5),
              onPressed: hasSource
                  ? () {
                      final pos = player.state.position;
                      player.seek(pos + const Duration(seconds: 5));
                    }
                  : null,
            ),
          ),
          // Volume: tap=mute toggle, long press=slider
          GestureDetector(
            onLongPressStart: hasSource
                ? (details) =>
                    _showVolumeMenu(context, details.globalPosition, player)
                : null,
            child: IconButton(
              icon: Icon(volume > 0 ? Icons.volume_up : Icons.volume_off),
              onPressed: hasSource
                  ? () => player.setVolume(volume > 0 ? 0.0 : 100.0)
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
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${rate}x',
                style: TextStyle(
                  fontSize: 13,
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
  const _VolumeDialog({required this.player, required this.anchor});

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
        // Tap anywhere to dismiss
        Positioned.fill(
          child: GestureDetector(onTap: () => Navigator.pop(context)),
        ),
        Positioned(
          left: (widget.anchor.dx - 100).clamp(8.0, MediaQuery.of(context).size.width - 208),
          top: widget.anchor.dy - 60,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () {
                      final newVol = _volume > 0 ? 0.0 : 100.0;
                      widget.player.setVolume(newVol);
                      setState(() => _volume = newVol);
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
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 7),
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
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
