import 'dart:math';

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

  // Zoom / pan
  double _zoomLevel = 1.0;
  double _panOffset = 0.5;
  bool _autoFollow = true;
  double _lastDragX = 0;

  double get _vpWidth => 1.0 / _zoomLevel;

  void _clampPan() {
    final vw = _vpWidth;
    final half = vw / 2;
    _panOffset = _panOffset.clamp(half, max(half, 1.0 - half));
  }

  void _zoomIn() {
    setState(() {
      _zoomLevel = (_zoomLevel * 2).clamp(1.0, 128.0);
      _clampPan();
    });
  }

  void _zoomOut() {
    setState(() {
      _zoomLevel = (_zoomLevel / 2).clamp(1.0, 128.0);
      if (_zoomLevel < 1.05) {
        _zoomLevel = 1.0;
        _autoFollow = true;
      }
      _clampPan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    var position =
        ref.watch(positionProvider).valueOrNull ?? player.state.position;
    var duration =
        ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    if (duration == Duration.zero) {
      duration = player.state.duration;
    }
    final loop = ref.watch(loopProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final waveform = ref.watch(waveformDataProvider);
    ref.watch(waveformLoadingProvider);
    final waveformError = ref.watch(waveformErrorProvider);

    // Page-based auto-follow
    ref.listen(positionProvider, (_, next) {
      if (!_autoFollow || _zoomLevel <= 1.0) return;
      final pos = next.valueOrNull;
      final dur = ref.read(durationProvider).valueOrNull;
      if (pos == null || dur == null || dur.inMilliseconds == 0) return;

      final posNorm = pos.inMilliseconds / dur.inMilliseconds;
      final vpW = 1.0 / _zoomLevel;
      final vs = (_panOffset - vpW / 2).clamp(0.0, max(0.0, 1.0 - vpW));

      if (posNorm < vs + vpW * 0.05 || posNorm > vs + vpW * 0.85) {
        final half = vpW / 2;
        setState(() {
          _panOffset =
              (posNorm + vpW * 0.3).clamp(half, max(half, 1.0 - half));
        });
      }
    });

    final vpWidth = 1.0 / _zoomLevel;
    final double viewStart =
        (_panOffset - vpWidth / 2).clamp(0.0, max(0.0, 1.0 - vpWidth)).toDouble();
    final double viewEnd = (viewStart + vpWidth).clamp(0.0, 1.0).toDouble();
    final isZoomed = _zoomLevel > 1.05;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: [
          // --- Main waveform ---
          SizedBox(
              height: 80,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;

                  double screenXToNorm(double x) =>
                      viewStart + (x / width) * vpWidth;

                  double normToScreenX(double n) =>
                      ((n - viewStart) / vpWidth) * width;

                  Duration normToDuration(double n) => Duration(
                      milliseconds:
                          (n.clamp(0.0, 1.0) * duration.inMilliseconds)
                              .round());

                  _DragTarget hitTest(double screenX) {
                    if (duration.inMilliseconds == 0) {
                      return _DragTarget.position;
                    }
                    const hitRadius = 24.0;
                    final totalMs = duration.inMilliseconds.toDouble();

                    if (loop.hasB) {
                      final bSX =
                          normToScreenX(loop.pointB!.inMilliseconds / totalMs);
                      if ((screenX - bSX).abs() < hitRadius) {
                        return _DragTarget.pointB;
                      }
                    }
                    if (loop.hasA) {
                      final aSX =
                          normToScreenX(loop.pointA!.inMilliseconds / totalMs);
                      if ((screenX - aSX).abs() < hitRadius) {
                        return _DragTarget.pointA;
                      }
                    }
                    return _DragTarget.position;
                  }

                  return GestureDetector(
                    onHorizontalDragStart: hasSource
                        ? (details) {
                            _activeDrag =
                                hitTest(details.localPosition.dx);
                            _lastDragX = details.localPosition.dx;
                          }
                        : null,
                    onHorizontalDragUpdate: hasSource
                        ? (details) {
                            final dx =
                                details.localPosition.dx - _lastDragX;
                            if (_activeDrag == _DragTarget.pointA) {
                              ref.read(loopProvider.notifier).setPointA(
                                  normToDuration(screenXToNorm(
                                      details.localPosition.dx)));
                            } else if (_activeDrag == _DragTarget.pointB) {
                              ref.read(loopProvider.notifier).setPointB(
                                  normToDuration(screenXToNorm(
                                      details.localPosition.dx)));
                            } else {
                              final deltaNorm = (dx / width) * 3.0;
                              final totalMs =
                                  duration.inMilliseconds.toDouble();
                              if (totalMs > 0) {
                                final curMs = ref
                                    .read(playerProvider)
                                    .state
                                    .position
                                    .inMilliseconds;
                                final newMs =
                                    (curMs + deltaNorm * totalMs).round();
                                final clamped = newMs.clamp(
                                    0, duration.inMilliseconds);
                                ref.read(playerProvider).seek(
                                    Duration(milliseconds: clamped));
                              }
                            }
                            _lastDragX = details.localPosition.dx;
                          }
                        : null,
                    onHorizontalDragEnd: (_) => _activeDrag = null,
                    onTapUp: hasSource
                        ? (details) {
                            final d = normToDuration(
                                screenXToNorm(details.localPosition.dx));
                            ref.read(playerProvider).seek(d);
                          }
                        : null,
                    child: Stack(
                      children: [
                        CustomPaint(
                          size: Size(width, 80),
                          painter: _WaveformSeekbarPainter(
                            position: position,
                            duration: duration,
                            pointA: loop.pointA,
                            pointB: loop.pointB,
                            loopEnabled: loop.enabled,
                            waveform: waveform,
                            brightness: Theme.of(context).brightness,
                            viewStart: viewStart,
                            viewEnd: viewEnd,
                          ),
                        ),
                        if (waveformError != null && waveform == null)
                          Positioned.fill(
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '波形: $waveformError',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white70,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),

          // --- Mini-map ---
          if (hasSource)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SizedBox(
                  height: 24,
                  width: double.infinity,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final mw = constraints.maxWidth;
                      return GestureDetector(
                        onTapDown: hasSource
                            ? (details) {
                                final norm = details.localPosition.dx / mw;
                                final half = _vpWidth / 2;
                                setState(() {
                                  _panOffset = norm.clamp(
                                      half, max(half, 1.0 - half));
                                  _autoFollow = false;
                                });
                              }
                            : null,
                        onHorizontalDragUpdate: hasSource
                            ? (details) {
                                final norm = details.localPosition.dx / mw;
                                final half = _vpWidth / 2;
                                setState(() {
                                  _panOffset = norm.clamp(
                                      half, max(half, 1.0 - half));
                                  _autoFollow = false;
                                });
                              }
                            : null,
                        child: CustomPaint(
                          size: Size(mw, 24),
                          painter: _MinimapPainter(
                            waveform: waveform,
                            viewStart: viewStart,
                            viewEnd: viewEnd,
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
              ),

          // --- Zoom controls + time display (combined row) ---
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              children: [
                // Current time (left)
                Text(
                  TimeUtils.format(position),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const Spacer(),
                // Zoom controls (center)
                if (hasSource) ...[
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      icon: const Icon(Icons.remove, size: 16),
                      onPressed: _zoomLevel > 1.05 ? _zoomOut : null,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '${_zoomLevel.toStringAsFixed(_zoomLevel >= 10 ? 0 : 1)}x',
                      style: TextStyle(
                        fontSize: 11,
                        color: isZoomed
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      icon: const Icon(Icons.add, size: 16),
                      onPressed: _zoomLevel < 128.0 ? _zoomIn : null,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  if (isZoomed && !_autoFollow) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => setState(() => _autoFollow = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '追従',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
                const Spacer(),
                // Total duration (right)
                Text(
                  TimeUtils.format(duration),
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

// =============================================================================
// Main waveform painter (viewport-aware)
// =============================================================================

class _WaveformSeekbarPainter extends CustomPainter {
  final Duration position;
  final Duration duration;
  final Duration? pointA;
  final Duration? pointB;
  final bool loopEnabled;
  final List<double>? waveform;
  final Brightness brightness;
  final double viewStart;
  final double viewEnd;

  _WaveformSeekbarPainter({
    required this.position,
    required this.duration,
    required this.pointA,
    required this.pointB,
    required this.loopEnabled,
    required this.waveform,
    required this.brightness,
    required this.viewStart,
    required this.viewEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = brightness == Brightness.dark;
    final totalMs = duration.inMilliseconds;
    final vpWidth = viewEnd - viewStart;

    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..color = isDark ? const Color(0xFF0D0D1A) : const Color(0xFFE0E0E0),
    );

    if (totalMs == 0 || vpWidth <= 0) {
      _drawMinimalTrack(canvas, size, 0, isDark);
      return;
    }

    double toX(Duration d) {
      final norm = (d.inMilliseconds / totalMs).clamp(0.0, 1.0);
      return ((norm - viewStart) / vpWidth) * size.width;
    }

    final posX = toX(position);
    final hasA = pointA != null;
    final hasB = pointB != null;
    final hasBoth = hasA && hasB;
    final aX = hasA ? toX(pointA!) : 0.0;
    final bX = hasB ? toX(pointB!) : 0.0;

    // Waveform or minimal track
    if (waveform != null && waveform!.isNotEmpty) {
      _drawWaveform(canvas, size, posX, isDark);
    } else {
      _drawMinimalTrack(canvas, size, posX, isDark);
    }

    // AB region highlight (subtle blue tint)
    if (hasBoth) {
      final clipAX = aX.clamp(0.0, size.width);
      final clipBX = bX.clamp(0.0, size.width);
      if (clipBX > clipAX) {
        canvas.drawRect(
          Rect.fromLTRB(clipAX, 0, clipBX, size.height),
          Paint()..color = AppTheme.pointBColor.withValues(alpha: 0.08),
        );
      }
    }

    // Position line
    if (posX >= 0 && posX <= size.width) {
      canvas.drawLine(
        Offset(posX, 0),
        Offset(posX, size.height),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2,
      );
    }

    // Determine if A and B overlap (same position)
    final abOverlap = hasBoth && (aX - bX).abs() < 2.0;

    // A marker
    if (hasA) {
      final mx = toX(pointA!);
      if (mx >= -20 && mx <= size.width + 20) {
        _drawMarkerLine(canvas, size, mx, 'A', AppTheme.pointAColor,
            labelAtBottom: abOverlap);
      }
    }

    // B marker
    if (hasB) {
      final mx = toX(pointB!);
      if (mx >= -20 && mx <= size.width + 20) {
        _drawMarkerLine(canvas, size, mx, 'B', AppTheme.pointBColor);
      }
    }
  }

  void _drawWaveform(
    Canvas canvas,
    Size size,
    double posX,
    bool isDark,
  ) {
    final data = waveform!;
    final barCount = data.length;
    final vpWidth = viewEnd - viewStart;
    final midY = size.height / 2;
    final maxBarH = size.height * 0.42;

    final startIdx = max(0, (viewStart * barCount).floor() - 1);
    final endIdx = min(barCount, (viewEnd * barCount).ceil() + 1);

    // Waveform uses accent green color (not B color)
    const waveColorDark = Color(0xFF4ECCA3);
    const waveColorLight = Color(0xFF00A86B);

    for (var i = startIdx; i < endIdx; i++) {
      final normPos = i / barCount;
      final normEnd = (i + 1) / barCount;

      final x = ((normPos - viewStart) / vpWidth) * size.width;
      final xEnd = ((normEnd - viewStart) / vpWidth) * size.width;
      final barW = xEnd - x;

      if (x + barW < 0 || x > size.width) continue;

      final h = max(data[i] * maxBarH, 1.0);

      // Alpha based on position only: before = 0.5, after = 0.25
      final alpha = x <= posX ? 0.5 : 0.25;
      final color = isDark
          ? waveColorDark.withValues(alpha: alpha)
          : waveColorLight.withValues(alpha: alpha);

      final gapW = barW * 0.8;
      final gapX = x + barW * 0.1;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(gapX + gapW / 2, midY),
            width: max(gapW, 1.0),
            height: h * 2,
          ),
          Radius.circular(max(gapW / 2, 0.5)),
        ),
        Paint()..color = color,
      );
    }
  }

  void _drawMinimalTrack(
    Canvas canvas,
    Size size,
    double posX,
    bool isDark,
  ) {
    final midY = size.height / 2;
    const trackH = 6.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(0, midY - trackH / 2, size.width, midY + trackH / 2),
        const Radius.circular(3),
      ),
      Paint()
        ..color = isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.grey.shade400,
    );

    if (posX > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
              0, midY - trackH / 2, posX.clamp(0, size.width), midY + trackH / 2),
          const Radius.circular(3),
        ),
        Paint()
          ..color = isDark
              ? const Color(0xFF4ECCA3).withValues(alpha: 0.5)
              : const Color(0xFF00A86B).withValues(alpha: 0.5),
      );
    }
  }

  void _drawMarkerLine(
    Canvas canvas,
    Size size,
    double x,
    String label,
    Color color, {
    bool labelAtBottom = false,
  }) {
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 2.5,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelW = tp.width + 8;
    final labelH = tp.height + 4;
    final labelX = (x - labelW / 2).clamp(0.0, size.width - labelW);
    final labelY = labelAtBottom ? size.height - labelH - 2 : 2.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(labelX, labelY, labelW, labelH),
        const Radius.circular(3),
      ),
      Paint()..color = color,
    );
    tp.paint(canvas, Offset(labelX + 4, labelY + 2));
  }

  @override
  bool shouldRepaint(covariant _WaveformSeekbarPainter old) =>
      old.position != position ||
      old.duration != duration ||
      old.pointA != pointA ||
      old.pointB != pointB ||
      old.loopEnabled != loopEnabled ||
      old.waveform != waveform ||
      old.viewStart != viewStart ||
      old.viewEnd != viewEnd;
}

// =============================================================================
// Mini-map painter (full overview)
// =============================================================================

class _MinimapPainter extends CustomPainter {
  final List<double>? waveform;
  final double viewStart;
  final double viewEnd;
  final Duration position;
  final Duration duration;
  final Duration? pointA;
  final Duration? pointB;
  final bool loopEnabled;
  final Brightness brightness;

  _MinimapPainter({
    required this.waveform,
    required this.viewStart,
    required this.viewEnd,
    required this.position,
    required this.duration,
    required this.pointA,
    required this.pointB,
    required this.loopEnabled,
    required this.brightness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = brightness == Brightness.dark;
    final totalMs = duration.inMilliseconds;

    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..color = isDark ? const Color(0xFF0A0A14) : const Color(0xFFD0D0D0),
    );

    if (totalMs == 0) return;

    double toX(Duration d) =>
        (d.inMilliseconds / totalMs).clamp(0.0, 1.0) * size.width;

    // Minimap waveform (accent green)
    if (waveform != null && waveform!.isNotEmpty) {
      final data = waveform!;
      final midY = size.height / 2;
      final maxH = size.height * 0.4;
      final targetBars = (size.width / 2).ceil();
      final step = max(1, (data.length / targetBars).ceil());

      for (var i = 0; i < data.length; i += step) {
        var maxVal = 0.0;
        final end = min(i + step, data.length);
        for (var j = i; j < end; j++) {
          if (data[j] > maxVal) maxVal = data[j];
        }
        final x = (i / data.length) * size.width;
        final w = (step / data.length) * size.width;
        final h = max(maxVal * maxH, 0.5);

        canvas.drawRect(
          Rect.fromCenter(
              center: Offset(x + w / 2, midY),
              width: max(w, 1),
              height: h * 2),
          Paint()
            ..color = isDark
                ? const Color(0xFF4ECCA3).withValues(alpha: 0.4)
                : const Color(0xFF00A86B).withValues(alpha: 0.4),
        );
      }
    }

    // AB region highlight (show when both are set, regardless of loopEnabled)
    if (pointA != null && pointB != null) {
      canvas.drawRect(
        Rect.fromLTRB(toX(pointA!), 0, toX(pointB!), size.height),
        Paint()..color = AppTheme.pointBColor.withValues(alpha: 0.15),
      );
    }

    // A marker line (show when set)
    if (pointA != null) {
      final aX = toX(pointA!);
      canvas.drawLine(
        Offset(aX, 0),
        Offset(aX, size.height),
        Paint()
          ..color = AppTheme.pointAColor
          ..strokeWidth = 1.5,
      );
    }

    // B marker line (show when set)
    if (pointB != null) {
      final bX = toX(pointB!);
      canvas.drawLine(
        Offset(bX, 0),
        Offset(bX, size.height),
        Paint()
          ..color = AppTheme.pointBColor
          ..strokeWidth = 1.5,
      );
    }

    // Position line
    final posX = toX(position);
    canvas.drawLine(
      Offset(posX, 0),
      Offset(posX, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1,
    );

    // Viewport indicator
    final vpLeft = viewStart * size.width;
    final vpRight = viewEnd * size.width;
    canvas.drawRect(
      Rect.fromLTRB(vpLeft, 0, vpRight, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );
    canvas.drawRect(
      Rect.fromLTRB(vpLeft, 0, vpRight, size.height),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) =>
      old.viewStart != viewStart ||
      old.viewEnd != viewEnd ||
      old.position != position ||
      old.duration != duration ||
      old.pointA != pointA ||
      old.pointB != pointB ||
      old.loopEnabled != loopEnabled ||
      old.waveform != waveform;
}
