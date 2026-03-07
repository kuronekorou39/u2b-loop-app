import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';

enum _DragTarget { position, pointA, pointB }

class LoopSeekbar extends ConsumerStatefulWidget {
  const LoopSeekbar({super.key});

  @override
  ConsumerState<LoopSeekbar> createState() => _LoopSeekbarState();
}

class _LoopSeekbarState extends ConsumerState<LoopSeekbar> {
  _DragTarget? _activeDrag;

  double _durationToX(Duration d, Duration total, double width) {
    if (total.inMilliseconds == 0) return 0;
    return (d.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0) * width;
  }

  Duration _xToDuration(double x, Duration total, double width) {
    if (width == 0) return Duration.zero;
    final ratio = (x / width).clamp(0.0, 1.0);
    return Duration(milliseconds: (ratio * total.inMilliseconds).round());
  }

  _DragTarget _hitTest(double x, Duration total, double width) {
    final loop = ref.read(loopProvider);
    const hitRadius = 20.0;

    if (loop.pointA > Duration.zero) {
      final aX = _durationToX(loop.pointA, total, width);
      if ((x - aX).abs() < hitRadius) return _DragTarget.pointA;
    }
    if (loop.pointB > Duration.zero) {
      final bX = _durationToX(loop.pointB, total, width);
      if ((x - bX).abs() < hitRadius) return _DragTarget.pointB;
    }
    return _DragTarget.position;
  }

  void _handleDrag(double localX, Duration total, double width) {
    final d = _xToDuration(localX, total, width);
    switch (_activeDrag) {
      case _DragTarget.pointA:
        ref.read(loopProvider.notifier).setPointA(d);
      case _DragTarget.pointB:
        ref.read(loopProvider.notifier).setPointB(d);
      case _DragTarget.position:
        ref.read(playerProvider).seek(d);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final position =
        ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration =
        ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final loop = ref.watch(loopProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  onHorizontalDragStart: hasSource
                      ? (details) {
                          _activeDrag =
                              _hitTest(details.localPosition.dx, duration, width);
                        }
                      : null,
                  onHorizontalDragUpdate: hasSource
                      ? (details) {
                          _handleDrag(
                              details.localPosition.dx, duration, width);
                        }
                      : null,
                  onHorizontalDragEnd: (_) => _activeDrag = null,
                  onTapDown: hasSource
                      ? (details) {
                          final d = _xToDuration(
                              details.localPosition.dx, duration, width);
                          ref.read(playerProvider).seek(d);
                        }
                      : null,
                  child: CustomPaint(
                    size: Size(width, 44),
                    painter: _SeekbarPainter(
                      position: position,
                      duration: duration,
                      pointA: loop.pointA,
                      pointB: loop.pointB,
                      loopEnabled: loop.enabled,
                      brightness: Theme.of(context).brightness,
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  TimeUtils.formatShort(position),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Text(
                  TimeUtils.formatShort(duration),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekbarPainter extends CustomPainter {
  final Duration position;
  final Duration duration;
  final Duration pointA;
  final Duration pointB;
  final bool loopEnabled;
  final Brightness brightness;

  _SeekbarPainter({
    required this.position,
    required this.duration,
    required this.pointA,
    required this.pointB,
    required this.loopEnabled,
    required this.brightness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackY = size.height / 2;
    const trackH = 4.0;
    final totalMs = duration.inMilliseconds;
    if (totalMs == 0) {
      // Empty track
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(size.width / 2, trackY),
            width: size.width,
            height: trackH,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = Colors.grey.shade800,
      );
      return;
    }

    double toX(Duration d) =>
        (d.inMilliseconds / totalMs).clamp(0.0, 1.0) * size.width;

    // Background track
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, trackY),
          width: size.width,
          height: trackH,
        ),
        const Radius.circular(2),
      ),
      Paint()
        ..color = brightness == Brightness.dark
            ? Colors.grey.shade800
            : Colors.grey.shade300,
    );

    // AB region highlight
    if (loopEnabled && pointB > Duration.zero) {
      final aX = toX(pointA);
      final bX = toX(pointB);
      canvas.drawRect(
        Rect.fromLTRB(aX, trackY - 8, bX, trackY + 8),
        Paint()..color = AppTheme.pointBColor.withValues(alpha: 0.2),
      );
    }

    // Progress
    final posX = toX(position);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(0, trackY - trackH / 2, posX, trackY + trackH / 2),
        const Radius.circular(2),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.7),
    );

    // A marker
    if (pointA > Duration.zero || loopEnabled) {
      final aX = toX(pointA);
      _drawMarker(canvas, aX, trackY, 'A', AppTheme.pointAColor);
    }

    // B marker
    if (pointB > Duration.zero) {
      final bX = toX(pointB);
      _drawMarker(canvas, bX, trackY, 'B', AppTheme.pointBColor);
    }

    // Position handle
    canvas.drawCircle(
      Offset(posX, trackY),
      7,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(posX, trackY),
      5,
      Paint()
        ..color = brightness == Brightness.dark
            ? const Color(0xFF4ECCA3)
            : const Color(0xFF00A86B),
    );
  }

  void _drawMarker(
      Canvas canvas, double x, double y, String label, Color color) {
    // Marker line
    canvas.drawLine(
      Offset(x, y - 14),
      Offset(x, y + 14),
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
    // Label
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, y - 22));
  }

  @override
  bool shouldRepaint(covariant _SeekbarPainter old) =>
      old.position != position ||
      old.duration != duration ||
      old.pointA != pointA ||
      old.pointB != pointB ||
      old.loopEnabled != loopEnabled;
}
