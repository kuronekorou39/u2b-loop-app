import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/player_provider.dart';

class PlayerControls extends ConsumerWidget {
  const PlayerControls({super.key});

  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _seekSteps = [1, 5, 10, 30];

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
          // Rewind (popup for step selection)
          PopupMenuButton<int>(
            onSelected: (sec) {
              final pos = player.state.position;
              final target = pos - Duration(seconds: sec);
              player.seek(target < Duration.zero ? Duration.zero : target);
            },
            enabled: hasSource,
            itemBuilder: (_) => _seekSteps
                .map((s) => PopupMenuItem(
                      value: s,
                      height: 36,
                      child: Text('-${s}s', style: const TextStyle(fontSize: 13)),
                    ))
                .toList(),
            child: IconButton(
              icon: const Icon(Icons.replay_5),
              onPressed: hasSource
                  ? () {
                      final pos = player.state.position;
                      final target = pos - const Duration(seconds: 5);
                      player
                          .seek(target < Duration.zero ? Duration.zero : target);
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
          // Forward (popup for step selection)
          PopupMenuButton<int>(
            onSelected: (sec) {
              final pos = player.state.position;
              player.seek(pos + Duration(seconds: sec));
            },
            enabled: hasSource,
            itemBuilder: (_) => _seekSteps
                .map((s) => PopupMenuItem(
                      value: s,
                      height: 36,
                      child: Text('+${s}s', style: const TextStyle(fontSize: 13)),
                    ))
                .toList(),
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
          // Volume (popup slider)
          PopupMenuButton<double>(
            onSelected: (_) {},
            enabled: hasSource,
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: StatefulBuilder(
                  builder: (context, setLocalState) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () {
                            final newVol = volume > 0 ? 0.0 : 100.0;
                            player.setVolume(newVol);
                          },
                          child: Icon(
                            volume > 0 ? Icons.volume_up : Icons.volume_off,
                            size: 20,
                          ),
                        ),
                        SizedBox(
                          width: 120,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7),
                            ),
                            child: Slider(
                              value: volume.clamp(0, 100),
                              min: 0,
                              max: 100,
                              onChanged: (v) {
                                player.setVolume(v);
                                setLocalState(() {});
                              },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
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
