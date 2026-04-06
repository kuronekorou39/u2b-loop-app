import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../models/loop_state.dart';
import '../../core/utils/time_utils.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';

enum _DragTarget { position, pointA, pointB }

class LoopSeekbar extends ConsumerStatefulWidget {
  final bool compact;
  final VoidCallback? onToggleCompact;
  final bool allowMarkerDrag;
  final VoidCallback? onRetryWaveform;

  const LoopSeekbar({
    super.key,
    this.compact = false,
    this.onToggleCompact,
    this.allowMarkerDrag = true,
    this.onRetryWaveform,
  });

  @override
  ConsumerState<LoopSeekbar> createState() => _LoopSeekbarState();
}

class _LoopSeekbarState extends ConsumerState<LoopSeekbar> {
  _DragTarget? _activeDrag;

  // Waveform retry
  bool _retrying = false;
  Timer? _retryTimer;
  String? _lastError;

  // Zoom / pan
  double _zoomLevel = 1.0;
  double _panOffset = 0.5;
  bool _autoFollow = true;
  double _lastDragX = 0;

  // Relative drag for AB markers (offset between finger and marker)
  double _dragOffset = 0;
  // Smooth position drag (accumulate deltas ourselves)
  double _dragStartPositionMs = 0;
  double _dragAccumulatedDeltaMs = 0;

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
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _scheduleRetry(String error) {
    if (_retrying || _lastError == error) return;
    _lastError = error;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _retrying = true);
      widget.onRetryWaveform?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    var position =
        ref.watch(positionProvider).valueOrNull ?? player.state.position;
    // durationProvider はプレーヤースワップ後に旧値をキャッシュするため
    // player.state.duration を優先（ストリームは rebuild トリガーとして使用）
    final durationStream = ref.watch(durationProvider).valueOrNull;
    var duration = player.state.duration;
    if (duration == Duration.zero) {
      duration = durationStream ?? Duration.zero;
    }
    final loop = ref.watch(loopProvider);
    final hasSource = ref.watch(videoSourceProvider) != null;
    final waveform = ref.watch(waveformDataProvider);
    ref.watch(waveformLoadingProvider);
    final waveformError = ref.watch(waveformErrorProvider);

    // 波形取得成功時にリトライ状態をリセット
    if (waveformError == null && (_retrying || _lastError != null)) {
      _retryTimer?.cancel();
      _retrying = false;
      _lastError = null;
    }

    // Auto-follow: keep position near 30% from left edge of viewport
    ref.listen(positionProvider, (_, next) {
      if (!_autoFollow || _zoomLevel <= 1.0) return;
      final pos = next.valueOrNull;
      final dur = ref.read(durationProvider).valueOrNull;
      if (pos == null || dur == null || dur.inMilliseconds == 0) return;

      final posNorm = pos.inMilliseconds / dur.inMilliseconds;
      final vpW = 1.0 / _zoomLevel;
      final half = vpW / 2;
      // Target: position at 30% from left edge
      final targetPan =
          (posNorm + vpW * 0.2).clamp(half, max(half, 1.0 - half)).toDouble();
      // Only update if position drifts outside 10%~80% of viewport
      final vs = (_panOffset - half).clamp(0.0, max(0.0, 1.0 - vpW)).toDouble();
      final relPos = (posNorm - vs) / vpW;
      if (relPos < 0.10 || relPos > 0.80) {
        setState(() {
          _panOffset = targetPan;
        });
      }
    });

    final vpWidth = 1.0 / _zoomLevel;
    final double viewStart =
        (_panOffset - vpWidth / 2).clamp(0.0, max(0.0, 1.0 - vpWidth)).toDouble();
    final double viewEnd = (viewStart + vpWidth).clamp(0.0, 1.0).toDouble();
    final isZoomed = _zoomLevel > 1.05;

    if (widget.compact) {
      return _buildCompactMode(context, position, duration, loop, hasSource);
    }

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
                    if (duration.inMilliseconds == 0 ||
                        !widget.allowMarkerDrag) {
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

                            final totalMs =
                                duration.inMilliseconds.toDouble();
                            if (_activeDrag == _DragTarget.pointA &&
                                loop.hasA &&
                                totalMs > 0) {
                              // Record offset so marker doesn't jump to finger
                              final aSX = normToScreenX(
                                  loop.pointA!.inMilliseconds / totalMs);
                              _dragOffset =
                                  aSX - details.localPosition.dx;
                            } else if (_activeDrag == _DragTarget.pointB &&
                                loop.hasB &&
                                totalMs > 0) {
                              final bSX = normToScreenX(
                                  loop.pointB!.inMilliseconds / totalMs);
                              _dragOffset =
                                  bSX - details.localPosition.dx;
                            } else {
                              _dragOffset = 0;
                              // Snapshot current position; accumulate deltas ourselves
                              _dragStartPositionMs = ref
                                  .read(playerProvider)
                                  .state
                                  .position
                                  .inMilliseconds
                                  .toDouble();
                              _dragAccumulatedDeltaMs = 0;
                            }
                          }
                        : null,
                    onHorizontalDragUpdate: hasSource
                        ? (details) {
                            if (_activeDrag == _DragTarget.pointA) {
                              // Relative drag: apply offset so marker stays under original grab point
                              ref.read(loopProvider.notifier).setPointA(
                                  normToDuration(screenXToNorm(
                                      details.localPosition.dx +
                                          _dragOffset)));
                            } else if (_activeDrag == _DragTarget.pointB) {
                              ref.read(loopProvider.notifier).setPointB(
                                  normToDuration(screenXToNorm(
                                      details.localPosition.dx +
                                          _dragOffset)));
                            } else {
                              // Smooth position drag: 1:1 mapping, accumulated deltas
                              final dx =
                                  details.localPosition.dx - _lastDragX;
                              final totalMs =
                                  duration.inMilliseconds.toDouble();
                              if (totalMs > 0) {
                                // Convert screen px delta to ms delta
                                final deltaNorm =
                                    (dx / width) * vpWidth;
                                _dragAccumulatedDeltaMs +=
                                    deltaNorm * totalMs;
                                final newMs = (_dragStartPositionMs +
                                        _dragAccumulatedDeltaMs)
                                    .round()
                                    .clamp(0, duration.inMilliseconds);
                                ref.read(playerProvider).seek(
                                    Duration(milliseconds: newMs));
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
                        if (waveformError != null && waveform == null) ...[
                          Builder(builder: (_) {
                            _scheduleRetry(waveformError);
                            return Positioned(
                              left: 0,
                              right: 0,
                              bottom: 2,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: AppRadius.borderXs,
                                    ),
                                    child: Text(
                                      '波形: $waveformError',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                  if (_retrying) ...[
                                    const SizedBox(width: AppSpacing.xs),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: AppSpacing.sm, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: AppRadius.borderXs,
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 10,
                                            height: 10,
                                            child:
                                                CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                              color: Colors.white70,
                                            ),
                                          ),
                                          SizedBox(width: AppSpacing.xs),
                                          Text(
                                            '再取得中...',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }),
                        ],
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
                      icon: const Icon(Icons.remove, size: AppIconSizes.s),
                      onPressed: _zoomLevel > 1.05 ? _zoomOut : null,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: AppRadius.borderXs,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
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
                      icon: const Icon(Icons.add, size: AppIconSizes.s),
                      onPressed: _zoomLevel < 128.0 ? _zoomIn : null,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: AppRadius.borderXs,
                        ),
                      ),
                    ),
                  ),
                  if (isZoomed && !_autoFollow) ...[
                    const SizedBox(width: AppSpacing.sm),
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
                // Compact toggle
                if (widget.onToggleCompact != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      icon: const Icon(Icons.unfold_less, size: AppIconSizes.s),
                      onPressed: widget.onToggleCompact,
                      padding: EdgeInsets.zero,
                      tooltip: 'コンパクト表示',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMode(BuildContext context, Duration position,
      Duration duration, LoopState loop, bool hasSource) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          Text(
            TimeUtils.format(position),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: SizedBox(
              height: 32,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return GestureDetector(
                    onTapUp: hasSource
                        ? (details) {
                            final norm = details.localPosition.dx / width;
                            final ms =
                                (norm.clamp(0.0, 1.0) *
                                        duration.inMilliseconds)
                                    .round();
                            ref
                                .read(playerProvider)
                                .seek(Duration(milliseconds: ms));
                          }
                        : null,
                    onHorizontalDragUpdate: hasSource
                        ? (details) {
                            final norm = details.localPosition.dx / width;
                            final ms =
                                (norm.clamp(0.0, 1.0) *
                                        duration.inMilliseconds)
                                    .round();
                            ref
                                .read(playerProvider)
                                .seek(Duration(milliseconds: ms));
                          }
                        : null,
                    child: CustomPaint(
                      size: Size(width, 32),
                      painter: _CompactSeekbarPainter(
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
          const SizedBox(width: AppSpacing.md),
          Text(
            TimeUtils.format(duration),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(width: AppSpacing.xs),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              icon: const Icon(Icons.unfold_more, size: AppIconSizes.s),
              onPressed: widget.onToggleCompact,
              padding: EdgeInsets.zero,
              tooltip: '波形表示',
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Compact seekbar painter
// =============================================================================

class _CompactSeekbarPainter extends CustomPainter {
  final Duration position;
  final Duration duration;
  final Duration? pointA;
  final Duration? pointB;
  final bool loopEnabled;
  final Brightness brightness;

  _CompactSeekbarPainter({
    required this.position,
    required this.duration,
    this.pointA,
    this.pointB,
    required this.loopEnabled,
    required this.brightness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = brightness == Brightness.dark;
    final totalMs = duration.inMilliseconds;
    final cy = size.height / 2;
    const barH = 4.0;
    const r = Radius.circular(2);

    // Background
    canvas.drawRRect(
      RRect.fromLTRBAndCorners(0, cy - barH / 2, size.width, cy + barH / 2,
          topLeft: r, topRight: r, bottomLeft: r, bottomRight: r),
      Paint()
        ..color = isDark ? const Color(0xFF2A2A3E) : const Color(0xFFD0D0D0),
    );

    if (totalMs <= 0) return;

    double toX(Duration d) =>
        (d.inMilliseconds / totalMs).clamp(0.0, 1.0) * size.width;

    // AB region
    if (loopEnabled && pointA != null && pointB != null) {
      final aX = toX(pointA!);
      final bX = toX(pointB!);
      canvas.drawRect(
        Rect.fromLTRB(aX, cy - barH / 2, bX, cy + barH / 2),
        Paint()..color = const Color(0xFF4ECCA3).withValues(alpha: 0.3),
      );
    }

    // Progress
    final posX = toX(position);
    if (posX > 0) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(0, cy - barH / 2, posX, cy + barH / 2,
            topLeft: r, bottomLeft: r),
        Paint()..color = const Color(0xFF4ECCA3),
      );
    }

    // A marker
    if (pointA != null) {
      final aX = toX(pointA!);
      canvas.drawLine(
        Offset(aX, cy - 6),
        Offset(aX, cy + 6),
        Paint()
          ..color = const Color(0xFFFF6B6B)
          ..strokeWidth = 1.5,
      );
    }

    // B marker
    if (pointB != null) {
      final bX = toX(pointB!);
      canvas.drawLine(
        Offset(bX, cy - 6),
        Offset(bX, cy + 6),
        Paint()
          ..color = const Color(0xFF4ECCA3)
          ..strokeWidth = 1.5,
      );
    }

    // Position dot
    canvas.drawCircle(Offset(posX, cy), 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _CompactSeekbarPainter old) =>
      position != old.position ||
      duration != old.duration ||
      pointA != old.pointA ||
      pointB != old.pointB ||
      loopEnabled != old.loopEnabled;
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

    // AB region highlight
    if (hasBoth) {
      final clipAX = aX.clamp(0.0, size.width);
      final clipBX = bX.clamp(0.0, size.width);
      if (clipBX > clipAX) {
        // Fill
        canvas.drawRect(
          Rect.fromLTRB(clipAX, 0, clipBX, size.height),
          Paint()..color = AppTheme.pointBColor.withValues(alpha: 0.15),
        );
        // Top/bottom border lines
        final borderPaint = Paint()
          ..color = AppTheme.pointBColor.withValues(alpha: 0.35)
          ..strokeWidth = 1;
        canvas.drawLine(
            Offset(clipAX, 0), Offset(clipBX, 0), borderPaint);
        canvas.drawLine(Offset(clipAX, size.height),
            Offset(clipBX, size.height), borderPaint);
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
