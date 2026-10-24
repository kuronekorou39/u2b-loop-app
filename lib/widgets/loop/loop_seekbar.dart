import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../models/loop_state.dart';
import '../../core/utils/time_utils.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';
import '../glass_panel.dart';

enum _DragTarget { position, pointA, pointB }

/// シークバーに塗る交差の範囲（その曲の時計）
typedef MixRange = ({Duration start, Duration end});

class LoopSeekbar extends ConsumerStatefulWidget {
  final bool compact;

  /// 波形つきの1段表示（ズーム・ミニマップ・時間行なし）。
  /// 再生画面の下部コントローラー用。compact が true ならそちらが優先
  final bool bar;

  /// bar モードの波形の高さ（compact のときは使わない）
  final double barHeight;
  final VoidCallback? onToggleCompact;
  final bool allowMarkerDrag;
  final VoidCallback? onRetryWaveform;

  /// プレイリストの交差の範囲（この曲の時計、bar モード）。紫で塗る。
  /// 曲の頭側（前の曲との交差）と終わり側（次の曲との交差）の 2 つまで。
  /// 以前は重ね表示の窓の端を線で印していたが、A/B の線と並んで線だらけになった
  final List<MixRange> mixRanges;

  /// バーの上に重ねて置くもの（プレイリストの重ね表示の帯、bar モード）。
  /// 細いバーと時刻行はそのままの位置に残り、その上に足す
  final Widget? above;

  /// 時刻行の左の枠に出すもの（プレイリストのデッキの開閉ボタン、bar モード）。
  /// 重ね表示の時刻行と同じ場所に出て、どちらの表示でも同じ所で押せる
  final Widget? timeRowLeading;

  const LoopSeekbar({
    super.key,
    this.compact = false,
    this.bar = false,
    this.barHeight = 72,
    this.onToggleCompact,
    this.allowMarkerDrag = true,
    this.onRetryWaveform,
    this.mixRanges = const [],
    this.above,
    this.timeRowLeading,
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
  int _retryCount = 0;
  static const _maxRetries = 3;
  String? _lastSourceUri; // トラック切替検知用（リトライ回数のリセット）

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
    // リトライ手段がなければスケジュールしない（「再取得中」表示の固着防止）
    if (widget.onRetryWaveform == null) return;
    if (_retrying || _lastError == error || _retryCount >= _maxRetries) return;
    _lastError = error;
    _retryTimer?.cancel();
    // リトライ間隔: 3秒, 6秒, 12秒（バックオフ）
    final delaySec = 3 * (1 << _retryCount);
    _retryTimer = Timer(Duration(seconds: delaySec), () {
      if (!mounted) return;
      _retryCount++;
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
    final source = ref.watch(videoSourceProvider);
    final hasSource = source != null;
    final waveform = ref.watch(waveformDataProvider);
    final waveformLoading = ref.watch(waveformLoadingProvider);
    final waveformError = ref.watch(waveformErrorProvider);

    // トラックが変わったらリトライ回数も含めて完全リセット
    if (source?.uri != _lastSourceUri) {
      _lastSourceUri = source?.uri;
      _retryTimer?.cancel();
      _retrying = false;
      _lastError = null;
      _retryCount = 0;
    }
    if (waveform != null && (_retrying || _lastError != null || _retryCount > 0)) {
      // 波形取得成功: リトライ状態を完全リセット
      _retryTimer?.cancel();
      _retrying = false;
      _lastError = null;
      _retryCount = 0;
    } else if (waveformError == null && (_retrying || _lastError != null)) {
      // エラークリア＝リトライによる再取得開始。表示状態のみ解除し、
      // _retryCount は維持して再失敗時のバックオフ・上限を効かせる
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

    // 開閉ボタンの無い compact（横画面の 1 行）だけ時刻を左右に置く。
    // 開閉できる compact は、開いたときと同じく時刻を下の行に出す（左右に置くと
    // バーが短くなる）
    if (widget.compact && widget.onToggleCompact == null) {
      return _buildCompactMode(context, position, duration, loop, hasSource);
    }
    if (widget.bar || widget.compact) {
      return _buildBarMode(context, position, duration, loop, hasSource,
          waveform, waveformLoading, waveformError);
    }

    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFeatures: const [FontFeature('tnum')],
        );
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
                        ..._waveformStatusOverlays(
                            waveform, waveformLoading, waveformError),
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

          // --- 時刻（左右）+ ズームと開閉（中央）の行 ---
          // 時刻は端に置き、ズームと開閉ボタンは左右の幅に関係なく真ん中に置く
          // （開閉ボタンを終了時刻の右に置くと、そのぶん終了時刻が内側にずれて見える）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: SizedBox(
              height: 36,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Row(
                    children: [
                      Text(TimeUtils.format(position), style: labelStyle),
                      const Spacer(),
                      Text(TimeUtils.format(duration), style: labelStyle),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasSource) _buildZoomControls(context, isZoomed),
                      if (widget.onToggleCompact != null) ...[
                        if (hasSource) const SizedBox(width: AppSpacing.sm),
                        _toggleButton(Icons.unfold_less, 'コンパクト表示'),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 波形の開閉ボタン。見た目は小さいが押せる範囲は 36px（以前は 24〜28px）
  /// 「−」「＋」2 つぶんの幅（1 つ = アイコン 16 + 余白 6×2）

  Widget _toggleButton(IconData icon, String tooltip) => IconButton(
        icon: Icon(icon, size: AppIconSizes.sm),
        onPressed: widget.onToggleCompact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
      );

  /// ズームの − / 倍率 / ＋（ズーム中に追従を切ったら「追従」）。
  /// 板の上のピルと同じ見た目（以前は角丸四角の IconButton で浮いていた）
  Widget _buildZoomControls(BuildContext context, bool isZoomed) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final dim = scheme.onSurface.withValues(alpha: 0.3);
    Widget pill(IconData icon, String tooltip, VoidCallback? onTap) => GlassPill(
          onTap: onTap,
          tooltip: tooltip,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Icon(icon,
              size: AppIconSizes.s, color: onTap == null ? dim : null),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill(Icons.remove, 'ズームアウト', isZoomed ? _zoomOut : null),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Text(
            '${_zoomLevel.toStringAsFixed(_zoomLevel >= 10 ? 0 : 1)}x',
            style: textTheme.labelSmall?.copyWith(
              color: isZoomed ? AppTheme.accentGreen : null,
              fontFeatures: const [FontFeature('tnum')],
            ),
          ),
        ),
        pill(Icons.add, 'ズームイン', _zoomLevel < 128.0 ? _zoomIn : null),
        if (isZoomed && !_autoFollow) ...[
          const SizedBox(width: AppSpacing.sm),
          GlassPill(
            onTap: () => setState(() => _autoFollow = true),
            active: true,
            tooltip: '再生位置に追従する',
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('追従',
                style: textTheme.labelSmall
                    ?.copyWith(color: AppTheme.accentGreen)),
          ),
        ],
      ],
    );
  }

  /// 波形の「読込中」「エラー + リトライ」の帯（波形の下端に重ねる）
  List<Widget> _waveformStatusOverlays(
      List<double>? waveform, bool waveformLoading, String? waveformError) {
    Widget badge(List<Widget> children) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: AppRadius.borderXs,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        );
    const spinner = SizedBox(
      width: 10,
      height: 10,
      child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70),
    );
    const textStyle = TextStyle(fontSize: 11, color: Colors.white70);

    return [
      if (waveformLoading && waveform == null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 2,
          child: Center(
            child: badge(const [
              spinner,
              SizedBox(width: AppSpacing.xs),
              Text('波形を読込中...', style: textStyle),
            ]),
          ),
        ),
      if (waveformError != null && waveform == null && !waveformLoading)
        Builder(builder: (_) {
          _scheduleRetry(waveformError);
          return Positioned(
            left: 0,
            right: 0,
            bottom: 2,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 例外の生文字列は長押し（tooltip）で見られるようにし、表示は短く
                  Tooltip(
                    message: waveformError,
                    child: badge(const [
                      Text('波形を取得できませんでした', style: textStyle),
                    ]),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  if (_retrying)
                    badge(const [
                      spinner,
                      SizedBox(width: AppSpacing.xs),
                      Text('再取得中...', style: textStyle),
                    ])
                  else if (widget.onRetryWaveform != null)
                    Material(
                      color: AppTheme.accentGreen.withValues(alpha: 0.85),
                      borderRadius: AppRadius.borderSm,
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: widget.onRetryWaveform,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                          child: Text('リトライ',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }),
    ];
  }

  /// bar モードのシークバー: 細いバーと、その上に曲全体の波形（閉じていれば無し）か
  /// 重ね表示の帯。その下に時刻と波形切替。
  /// タップ/ドラッグでシーク
  Widget _buildBarMode(
    BuildContext context,
    Duration position,
    Duration duration,
    LoopState loop,
    bool hasSource,
    List<double>? waveform,
    bool waveformLoading,
    String? waveformError,
  ) {
    final compact = widget.compact;
    final brightness = Theme.of(context).brightness;

    /// タップ・横ドラッグでシークできる面。[waveformPainter] なら波形、でなければ細いバー
    Widget seekSurface({required bool waveformPainter, required double height}) =>
        SizedBox(
          height: height,
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              void seekTo(double x) {
                if (duration.inMilliseconds == 0) return;
                final norm = (x / width).clamp(0.0, 1.0);
                ref.read(playerProvider).seek(Duration(
                    milliseconds: (norm * duration.inMilliseconds).round()));
              }

              return GestureDetector(
                onTapUp: hasSource ? (d) => seekTo(d.localPosition.dx) : null,
                onHorizontalDragUpdate:
                    hasSource ? (d) => seekTo(d.localPosition.dx) : null,
                child: Stack(
                  children: [
                    CustomPaint(
                      size: Size(width, height),
                      painter: waveformPainter
                          ? _WaveformSeekbarPainter(
                              position: position,
                              duration: duration,
                              pointA: loop.pointA,
                              pointB: loop.pointB,
                              loopEnabled: loop.enabled,
                              waveform: waveform,
                              brightness: brightness,
                              viewStart: 0,
                              viewEnd: 1,
                              mixRanges: widget.mixRanges,
                            )
                          : _CompactSeekbarPainter(
                              position: position,
                              duration: duration,
                              pointA: loop.pointA,
                              pointB: loop.pointB,
                              loopEnabled: loop.enabled,
                              brightness: brightness,
                              mixRanges: widget.mixRanges,
                            ),
                    ),
                    if (waveformPainter)
                      ..._waveformStatusOverlays(
                          waveform, waveformLoading, waveformError),
                  ],
                ),
              );
            },
          ),
        );

    // 細いバーは常に出す。上には重ね表示の帯か、開いていれば曲全体の波形を置く
    // （重ね表示と単体で形を揃え、切り替わったときに表示が大きく動かないように）
    final above = widget.above ??
        (compact
            ? null
            : seekSurface(waveformPainter: true, height: widget.barHeight));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        children: [
          if (above != null) ...[
            above,
            const SizedBox(height: AppSpacing.xs),
          ],
          seekSurface(waveformPainter: false, height: 28),
          SeekTimeRow(
            position: position,
            duration: duration,
            compact: compact,
            onToggleCompact: widget.onToggleCompact,
            leading: widget.timeRowLeading,
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
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontFeatures: const [FontFeature('tnum')],
            ),
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
          if (widget.onToggleCompact != null) ...[
            const SizedBox(width: AppSpacing.xs),
            _toggleButton(Icons.unfold_more, '波形表示'),
          ],
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
  final List<MixRange> mixRanges;

  _CompactSeekbarPainter({
    required this.position,
    required this.duration,
    this.pointA,
    this.pointB,
    required this.loopEnabled,
    required this.brightness,
    this.mixRanges = const [],
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
        Paint()..color = AppTheme.pointBColor.withValues(alpha: 0.3),
      );
    }

    // Progress
    final posX = toX(position);
    if (posX > 0) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(0, cy - barH / 2, posX, cy + barH / 2,
            topLeft: r, bottomLeft: r),
        Paint()..color = AppTheme.accentGreen,
      );
    }

    // 交差の範囲（バーより少し太く塗る）
    for (final r in mixRanges) {
      final x0 = toX(r.start);
      final x1 = toX(r.end);
      if (x1 <= x0) continue;
      canvas.drawRRect(
        RRect.fromLTRBR(x0, cy - 4, x1, cy + 4, const Radius.circular(2)),
        Paint()..color = AppTheme.mixLineColor.withValues(alpha: 0.6),
      );
    }

    // A / B marker
    if (pointA != null) {
      final aX = toX(pointA!);
      drawPointLine(
          canvas, Offset(aX, cy - 6), Offset(aX, cy + 6), AppTheme.pointAColor);
    }
    if (pointB != null) {
      final bX = toX(pointB!);
      drawPointLine(
          canvas, Offset(bX, cy - 6), Offset(bX, cy + 6), AppTheme.pointBColor);
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
      loopEnabled != old.loopEnabled ||
      !listEquals(mixRanges, old.mixRanges);
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
  final List<MixRange> mixRanges;

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
    this.mixRanges = const [],
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

    // 交差の範囲（薄く塗る。線は引かない）
    for (final r in mixRanges) {
      final x0 = toX(r.start).clamp(0.0, size.width);
      final x1 = toX(r.end).clamp(0.0, size.width);
      if (x1 <= x0) continue;
      canvas.drawRect(
        Rect.fromLTRB(x0, 0, x1, size.height),
        Paint()..color = AppTheme.mixLineColor.withValues(alpha: 0.22),
      );
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
    const waveColorDark = AppTheme.accentGreen;
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
              ? AppTheme.accentGreen.withValues(alpha: 0.5)
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
    drawPointLine(canvas, Offset(x, 0), Offset(x, size.height), color);

    // 札: AB 編集の行と同じ作り（色を薄く敷いて、文字は色そのもの）。
    // 波形の上でも読めるよう、下に暗い地を敷いて細い縁取りを付ける
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelW = tp.width + 10;
    final labelH = tp.height + 4;
    final labelX = (x - labelW / 2).clamp(0.0, size.width - labelW);
    final labelY = labelAtBottom ? size.height - labelH - 2 : 2.0;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelX, labelY, labelW, labelH),
      const Radius.circular(6),
    );
    canvas.drawRRect(rect, Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: 0.22));
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    tp.paint(canvas, Offset(labelX + 5, labelY + 2));
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
      old.viewEnd != viewEnd ||
      !listEquals(old.mixRanges, mixRanges);
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
                ? AppTheme.accentGreen.withValues(alpha: 0.4)
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

    // A / B marker line (show when set)
    if (pointA != null) {
      final aX = toX(pointA!);
      drawPointLine(
          canvas, Offset(aX, 0), Offset(aX, size.height), AppTheme.pointAColor);
    }
    if (pointB != null) {
      final bX = toX(pointB!);
      drawPointLine(
          canvas, Offset(bX, 0), Offset(bX, size.height), AppTheme.pointBColor);
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

/// A/B 点の線。ガラス風に合わせて、細い芯の周りにほんのり同じ色を滲ませる
/// （以前は 1.5〜2.5px の不透明な 1 本線で、板の上で硬く見えた）
void drawPointLine(Canvas canvas, Offset top, Offset bottom, Color color) {
  canvas.drawLine(
    top,
    bottom,
    Paint()
      ..color = color.withValues(alpha: 0.22)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round,
  );
  canvas.drawLine(
    top,
    bottom,
    Paint()
      ..color = color.withValues(alpha: 0.95)
      ..strokeWidth = 1.5,
  );
}

// =============================================================================
// 再利用する部品（プレイリストの重ね表示が、前曲用・次曲用の棒と時刻行を組むのに使う）
// =============================================================================

/// 細い棒のシークバー 1 本（4px の棒、進んだ分は緑、交差の範囲は紫、白い点が位置）。
/// どのプレイヤーにも縛られない: 位置・長さ・シーク先の処理は呼ぶ側が渡す。
/// [onSeek] が null なら見るだけ
class ThinSeekbar extends StatelessWidget {
  const ThinSeekbar({
    super.key,
    required this.position,
    required this.duration,
    this.mixRanges = const [],
    this.onSeek,
    this.height = defaultHeight,
    this.pointA,
    this.pointB,
    this.loopEnabled = false,
  });

  final Duration position;
  final Duration duration;
  final List<MixRange> mixRanges;
  final ValueChanged<Duration>? onSeek;
  final double height;

  /// 高さの既定（次曲の棒はこれ。前曲の棒は細く）
  static const defaultHeight = 28.0;
  final Duration? pointA;
  final Duration? pointB;
  final bool loopEnabled;

  @override
  Widget build(BuildContext context) {
    final onSeek = this.onSeek;
    final brightness = Theme.of(context).brightness;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          void seekTo(double x) {
            if (onSeek == null || duration.inMilliseconds == 0 || width <= 0) {
              return;
            }
            final norm = (x / width).clamp(0.0, 1.0);
            onSeek(Duration(
                milliseconds: (norm * duration.inMilliseconds).round()));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: onSeek == null ? null : (d) => seekTo(d.localPosition.dx),
            onHorizontalDragUpdate:
                onSeek == null ? null : (d) => seekTo(d.localPosition.dx),
            child: CustomPaint(
              size: Size(width, height),
              painter: _CompactSeekbarPainter(
                position: position,
                duration: duration,
                pointA: pointA,
                pointB: pointB,
                loopEnabled: loopEnabled,
                brightness: brightness,
                mixRanges: mixRanges,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 時刻行: 時刻は端に、開閉ボタンは真ん中に（開くときも閉じるときも、重ね表示でも同じ場所）。
/// 開閉ボタンの左の枠に [leading]（重ね表示のデッキの開閉）を置ける。右にも同じ幅を
/// 空けて開閉ボタンを真ん中に保つ（「−」「＋」はデッキの板へ移した。右の枠は空）
class SeekTimeRow extends StatelessWidget {
  const SeekTimeRow({
    super.key,
    required this.position,
    required this.duration,
    this.compact = false,
    this.onToggleCompact,
    this.leading,
  });

  final Duration position;
  final Duration duration;
  final bool compact;
  final VoidCallback? onToggleCompact;
  final Widget? leading;

  /// 開閉ボタンの両脇の枠の幅
  static const sideWidth = 64.0;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFeatures: const [FontFeature('tnum')],
        );
    final sides = leading != null;
    return SizedBox(
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            children: [
              Text(TimeUtils.format(position), style: labelStyle),
              const Spacer(),
              Text(TimeUtils.format(duration), style: labelStyle),
            ],
          ),
          if (onToggleCompact != null || sides)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (sides)
                  SizedBox(
                    width: sideWidth,
                    child: leading == null
                        ? null
                        : Align(
                            alignment: Alignment.centerRight, child: leading),
                  ),
                if (onToggleCompact != null)
                  IconButton(
                    icon: Icon(compact ? Icons.unfold_more : Icons.unfold_less,
                        size: AppIconSizes.sm),
                    onPressed: onToggleCompact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    visualDensity: VisualDensity.compact,
                    tooltip: compact ? '波形表示' : 'コンパクト表示',
                  ),
                if (sides) const SizedBox(width: sideWidth),
              ],
            ),
        ],
      ),
    );
  }
}
