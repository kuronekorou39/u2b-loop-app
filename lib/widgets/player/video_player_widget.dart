import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../providers/player_provider.dart';

class VideoPlayerWidget extends ConsumerWidget {
  const VideoPlayerWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(videoSourceProvider);
    final controller = ref.watch(videoControllerProvider);

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: source == null
          ? Container(
              color: Colors.black,
              child: const Center(
                child: Text(
                  '動画を読み込んでください',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              ),
            )
          : Video(
              controller: controller,
              controls: NoVideoControls,
            ),
    );
  }
}
