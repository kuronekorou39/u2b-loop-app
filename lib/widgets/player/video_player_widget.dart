import 'dart:math';
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
    final flipH = ref.watch(flipHorizontalProvider);
    final flipV = ref.watch(flipVerticalProvider);

    Widget videoWidget;
    if (source == null) {
      videoWidget = Container(
        color: Colors.black,
        child: const Center(
          child: Text(
            '動画を読み込んでください',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
        ),
      );
    } else {
      videoWidget = Video(
        controller: controller,
        controls: NoVideoControls,
      );
    }

    if (flipH || flipV) {
      videoWidget = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
            flipH ? -1.0 : 1.0, flipV ? -1.0 : 1.0, 1.0),
        child: videoWidget,
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        children: [
          Positioned.fill(child: videoWidget),
          if (source != null)
            Positioned(
              right: 4,
              top: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FlipButton(
                    icon: Icons.flip,
                    active: flipH,
                    tooltip: '左右反転',
                    onTap: () => ref
                        .read(flipHorizontalProvider.notifier)
                        .state = !flipH,
                  ),
                  const SizedBox(width: 2),
                  _FlipButton(
                    icon: Icons.flip,
                    active: flipV,
                    rotate: true,
                    tooltip: '上下反転',
                    onTap: () => ref
                        .read(flipVerticalProvider.notifier)
                        .state = !flipV,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FlipButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final bool rotate;
  final String tooltip;
  final VoidCallback onTap;

  const _FlipButton({
    required this.icon,
    required this.active,
    this.rotate = false,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.25)
              : Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Transform.rotate(
          angle: rotate ? pi / 2 : 0,
          child: Icon(
            icon,
            size: 16,
            color: active ? Colors.white : Colors.white60,
          ),
        ),
      ),
    );
  }
}
