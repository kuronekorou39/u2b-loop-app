import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/player_provider.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key});

  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

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
          IconButton(
            icon: const Icon(Icons.replay_5),
            onPressed: hasSource
                ? () {
                    final pos = player.state.position;
                    player.seek(pos - const Duration(seconds: 5));
                  }
                : null,
          ),
          IconButton(
            icon: Icon(
              playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
            ),
            iconSize: 48,
            onPressed: hasSource ? () => player.playOrPause() : null,
            color: Theme.of(context).colorScheme.primary,
          ),
          IconButton(
            icon: const Icon(Icons.forward_5),
            onPressed: hasSource
                ? () {
                    final pos = player.state.position;
                    player.seek(pos + const Duration(seconds: 5));
                  }
                : null,
          ),
          IconButton(
            icon: Icon(volume > 0 ? Icons.volume_up : Icons.volume_off),
            onPressed: hasSource
                ? () => player.setVolume(volume > 0 ? 0.0 : 100.0)
                : null,
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
