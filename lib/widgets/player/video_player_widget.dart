import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/player_provider.dart';

class VideoPlayerWidget extends ConsumerStatefulWidget {
  const VideoPlayerWidget({super.key});

  @override
  ConsumerState<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends ConsumerState<VideoPlayerWidget> {
  bool _showOverlay = false;
  Timer? _hideTimer;

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    _hideTimer?.cancel();
    if (_showOverlay) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showOverlay = false);
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(videoSourceProvider);
    final controller = ref.watch(videoControllerProvider);
    final slot = ref.watch(activeSlotProvider);
    final flipH = ref.watch(flipHorizontalProvider);
    final flipV = ref.watch(flipVerticalProvider);

    Widget videoWidget;
    if (source == null) {
      videoWidget = Container(
        color: Colors.black,
        child: Center(
          child: Text(
            '動画を読み込んでください',
            style: Theme.of(context).textTheme.bodyLarge!
                .copyWith(color: Colors.grey),
          ),
        ),
      );
    } else {
      videoWidget = Video(
        key: ValueKey(slot),
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
      child: GestureDetector(
        onTap: source != null ? _toggleOverlay : null,
        child: Stack(
          children: [
            Positioned.fill(child: videoWidget),
            if (source != null && _showOverlay)
              Positioned(
                right: 4,
                top: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FlipButton(
                      icon: Icons.flip,
                      active: flipH,
                      onTap: () => ref
                          .read(flipHorizontalProvider.notifier)
                          .state = !flipH,
                    ),
                    const SizedBox(width: 2),
                    _FlipButton(
                      icon: Icons.flip,
                      active: flipV,
                      rotate: true,
                      onTap: () => ref
                          .read(flipVerticalProvider.notifier)
                          .state = !flipV,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FlipButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final bool rotate;
  final VoidCallback onTap;

  const _FlipButton({
    required this.icon,
    required this.active,
    this.rotate = false,
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
          borderRadius: AppRadius.borderXs,
        ),
        child: Transform.rotate(
          angle: rotate ? pi / 2 : 0,
          child: Icon(
            icon,
            size: AppIconSizes.s,
            color: active ? Colors.white : Colors.white60,
          ),
        ),
      ),
    );
  }
}
