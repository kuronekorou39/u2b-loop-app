import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/theme/app_theme.dart';

/// 重ね表示の窓（見えている範囲。旧曲の時計）
class MixWindow {
  const MixWindow(this.start, this.end);

  final Duration start;
  final Duration end;

  Duration get span => end - start;

  bool contains(Duration t) => t >= start && t <= end;

  @override
  bool operator ==(Object other) =>
      other is MixWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'MixWindow($start〜$end)';
}

/// 曲の切り替わり前後の「ミックスビュー」。
///
/// 1 曲目の頭から 2 曲目の終わりまでを 1 本の時間軸（旧曲の時計）として持ち、
/// その一部（[window] = 交差の前後に余白を付けた範囲）を描く。上段に旧曲の波形、
/// 下段に次曲の波形を同じ時間軸で縦に並べ、その上に 2 本の音量曲線（旧曲は下がる・
/// 次曲は上がる）と再生位置を重ねる。
///
/// 窓は「重ね表示を出す範囲」そのもの: 親は再生位置がこの中にある間だけ出し、
/// 外ではふつうのシークバー（窓の端を線で印す）に戻す。
/// これは帯だけ。親（PlaylistSeekArea）が [LoopSeekbar] の上に置き、
/// 細いシークバー・時刻行・「−」「＋」（余白を 1 段ずつ広げる・狭める）はそちらにある。
/// 操作: 帯の上のタップ・ドラッグはシーク（[onSeek]）だけ。
/// 2 本指のつまみは細い帯では安定しないので使わない
class MixView extends StatelessWidget {
  const MixView({
    super.key,
    required this.outWaveform,
    required this.outDuration,
    required this.outTitle,
    required this.inWaveform,
    required this.inDuration,
    required this.inStart,
    required this.inTitle,
    required this.start,
    required this.cut,
    required this.now,
    required this.swapped,
    required this.window,
    this.height = 72,
    this.curve = CrossfadeCurve.defaultCurve,
    this.bassSwap = false,
    this.onSeek,
  });

  /// 見えている範囲（旧曲の時計）。[windowAround] で作る
  final MixWindow window;

  /// タップ・横ドラッグで時間軸上の位置（旧曲の時計）を返す。null なら操作できない
  final ValueChanged<Duration>? onSeek;

  /// つなぎ方（音量曲線）。エンジンと同じものを描く
  final CrossfadeCurve curve;

  /// ベーススワップの位置に印を出す
  final bool bassSwap;

  /// 旧曲（上段）
  final List<double>? outWaveform;
  final Duration outDuration;
  final String outTitle;

  /// 次曲（下段）。[inStart] は次曲が鳴り始める位置（曲頭の無音や A 点の後）
  final List<double>? inWaveform;
  final Duration inDuration;
  final Duration inStart;
  final String inTitle;

  /// 交差の開始と切り替わり地点（旧曲の時計）
  final Duration start;
  final Duration cut;

  /// 再生位置（旧曲の時計に換算したもの）
  final Duration now;

  /// 切り替わり済みか（旧曲は止まっている）
  final bool swapped;

  final double height;

  /// 交差の前後に付ける余白の段。「−」で 1 段右（広く）、「＋」で 1 段左（狭く）
  static const margins = [
    Duration.zero,
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 32),
    Duration(seconds: 64),
  ];

  /// 最初の余白。一番狭い（交差だけ）から 1 段広げたところ。
  /// 16 秒では広すぎた（ユーザー: 交差だけの次の段がちょうどいい）
  static const defaultMargin = Duration(seconds: 4);

  /// 窓の幅の下限（交差が短く余白も無いときに、点にならないように）
  static const minSpanFloor = Duration(seconds: 2);

  /// [margin] の 1 段狭い余白。もう無ければ null
  static Duration? narrower(Duration margin) {
    final i = _marginIndex(margin);
    return i <= 0 ? null : margins[i - 1];
  }

  /// [margin] の 1 段広い余白。もう無ければ null
  static Duration? wider(Duration margin) {
    final i = _marginIndex(margin);
    return i >= margins.length - 1 ? null : margins[i + 1];
  }

  static int _marginIndex(Duration margin) {
    for (var i = 0; i < margins.length; i++) {
      if (margins[i] >= margin) return i;
    }
    return margins.length - 1;
  }

  /// 交差（[start]〜[cut]）の前後に [margin] を付けた窓。時間軸（0〜[timelineEnd]）に収め、
  /// [minSpanFloor] より狭ければ両側に広げる
  static MixWindow windowAround({
    required Duration start,
    required Duration cut,
    required Duration margin,
    required Duration timelineEnd,
  }) {
    var s = start - margin;
    var e = cut + margin;
    final short = minSpanFloor - (e - s);
    if (short > Duration.zero) {
      s -= short ~/ 2;
      e = s + minSpanFloor;
    }
    if (s < Duration.zero) s = Duration.zero;
    if (e > timelineEnd) e = timelineEnd;
    if (e < s) e = s;
    return MixWindow(s, e);
  }

  /// 幅 [width] のビューの x 座標を時間軸（旧曲の時計）に直す。端を超えた分は窓の端に丸める
  static Duration timeAtX(double x, double width, {required MixWindow window}) {
    if (width <= 0) return window.start;
    final p = (x / width).clamp(0.0, 1.0);
    return window.start + window.span * p;
  }

  @override
  Widget build(BuildContext context) {
    final laneLabel = Theme.of(context).textTheme.labelSmall!;
    final onSeek = this.onSeek;

    // 横の余白は置き場（LoopSeekbar の上）が持つ
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void seekAt(double x) => onSeek?.call(
            MixView.timeAtX(x, constraints.maxWidth, window: window),
          );
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: onSeek == null ? null : (d) => seekAt(d.localPosition.dx),
            onHorizontalDragUpdate: onSeek == null
                ? null
                : (d) => seekAt(d.localPosition.dx),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _MixPainter(
                      outWaveform: outWaveform,
                      outDuration: outDuration,
                      inWaveform: inWaveform,
                      inDuration: inDuration,
                      inStart: inStart,
                      start: start,
                      cut: cut,
                      now: now,
                      swapped: swapped,
                      window: window,
                      curve: curve,
                      bassSwap: bassSwap,
                    ),
                  ),
                ),
                Positioned(
                  left: 4,
                  top: 2,
                  right: 4,
                  child: _LaneLabel(
                    text: outTitle,
                    color: AppTheme.pointAColor,
                    style: laneLabel,
                  ),
                ),
                Positioned(
                  left: 4,
                  bottom: 2,
                  right: 4,
                  child: _LaneLabel(
                    text: '次: $inTitle',
                    color: AppTheme.pointBColor,
                    style: laneLabel,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LaneLabel extends StatelessWidget {
  const _LaneLabel({
    required this.text,
    required this.color,
    required this.style,
  });
  final String text;
  final Color color;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            text,
            style: style.copyWith(
              color: Colors.white.withValues(alpha: 0.8),
              shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MixPainter extends CustomPainter {
  _MixPainter({
    required this.outWaveform,
    required this.outDuration,
    required this.inWaveform,
    required this.inDuration,
    required this.inStart,
    required this.start,
    required this.cut,
    required this.now,
    required this.swapped,
    required this.window,
    required this.curve,
    required this.bassSwap,
  });

  final bool bassSwap;
  final List<double>? outWaveform;
  final Duration outDuration;
  final List<double>? inWaveform;
  final Duration inDuration;
  final Duration inStart;
  final Duration start;
  final Duration cut;
  final Duration now;
  final bool swapped;
  final MixWindow window;
  final CrossfadeCurve curve;

  static const _barStep = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final laneH = h / 2;
    final winStart = window.start.inMilliseconds.toDouble();
    final winEnd = window.end.inMilliseconds.toDouble();
    final span = max(1.0, winEnd - winStart);
    double toX(double tMs) => (tMs - winStart) / span * w;
    double toT(double x) => winStart + x / w * span;

    final startX = toX(start.inMilliseconds.toDouble());
    final cutX = toX(cut.inMilliseconds.toDouble());
    final nowMs = now.inMilliseconds.toDouble();
    final nowX = toX(nowMs);

    // 段の境界
    canvas.drawLine(
      Offset(0, laneH),
      Offset(w, laneH),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..strokeWidth = 1,
    );

    // 波形（上段: 旧曲、下段: 次曲）
    _drawLane(
      canvas,
      top: 0,
      laneH: laneH,
      w: w,
      toT: toT,
      waveform: outWaveform,
      durationMs: outDuration.inMilliseconds,
      // 旧曲の時計そのまま。切り替わり後は止まっている
      toTrackMs: (t) => t > cut.inMilliseconds ? null : t,
      playedUntilMs: swapped ? cut.inMilliseconds.toDouble() : nowMs,
      color: AppTheme.pointAColor,
    );
    _drawLane(
      canvas,
      top: laneH,
      laneH: laneH,
      w: w,
      toT: toT,
      waveform: inWaveform,
      durationMs: inDuration.inMilliseconds,
      // 次曲は交差開始で inStart から鳴り始める
      toTrackMs: (t) => t < start.inMilliseconds
          ? null
          : inStart.inMilliseconds + (t - start.inMilliseconds),
      playedUntilMs: nowMs,
      color: AppTheme.pointBColor,
    );

    // 音量曲線（設定のつなぎ方）。全高で描く
    final outPath = Path();
    final inPath = Path();
    const pad = 3.0;
    double yOf(double level) => h - pad - level * (h - pad * 2);
    for (var x = 0.0; x <= w; x += 2) {
      final t = toT(x);
      final double outLevel, inLevel;
      if (t <= start.inMilliseconds) {
        outLevel = 1;
        inLevel = 0;
      } else if (t >= cut.inMilliseconds) {
        outLevel = 0;
        inLevel = 1;
      } else {
        final p =
            (t - start.inMilliseconds) / max(1, (cut - start).inMilliseconds);
        final levels = curve.levels(p);
        outLevel = levels.out;
        inLevel = levels.in_;
      }
      if (x == 0) {
        outPath.moveTo(x, yOf(outLevel));
        inPath.moveTo(x, yOf(inLevel));
      } else {
        outPath.lineTo(x, yOf(outLevel));
        inPath.lineTo(x, yOf(inLevel));
      }
    }
    canvas.drawPath(
      outPath,
      Paint()
        ..color = AppTheme.pointAColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      inPath,
      Paint()
        ..color = AppTheme.pointBColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    // 切り替わり地点
    if (cutX >= 0 && cutX <= w) {
      canvas.drawLine(
        Offset(cutX, 0),
        Offset(cutX, h),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.35)
          ..strokeWidth = 1,
      );
    }

    // ベーススワップの位置（点線）
    if (bassSwap && curve.bassSwapAt < 1) {
      final bx = startX + (cutX - startX) * curve.bassSwapAt;
      if (bx >= 0 && bx <= w) {
        final paint = Paint()
          ..color = Colors.amber.withValues(alpha: 0.7)
          ..strokeWidth = 1;
        for (var y = 0.0; y < h; y += 6) {
          canvas.drawLine(Offset(bx, y), Offset(bx, min(y + 3, h)), paint);
        }
      }
    }

    // 再生位置
    if (nowX >= 0 && nowX <= w) {
      canvas.drawLine(
        Offset(nowX, 0),
        Offset(nowX, h),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2,
      );
    }
  }

  /// 1 段ぶんの波形。棒 1 本が覆う範囲の最大値を取る（縮小しても山が消えない）
  void _drawLane(
    Canvas canvas, {
    required double top,
    required double laneH,
    required double w,
    required double Function(double x) toT,
    required List<double>? waveform,
    required int durationMs,
    required double? Function(double t) toTrackMs,
    required double playedUntilMs,
    required Color color,
  }) {
    if (waveform == null || waveform.isEmpty || durationMs <= 0) return;
    final midY = top + laneH / 2;
    final maxBarH = laneH * 0.44;
    final n = waveform.length;
    for (var x = 0.0; x < w; x += _barStep) {
      final t = toT(x);
      final trackMs = toTrackMs(t);
      if (trackMs == null || trackMs < 0 || trackMs >= durationMs) continue;
      final nextMs = toTrackMs(toT(x + _barStep)) ?? trackMs;
      final idx0 = (trackMs / durationMs * n).floor().clamp(0, n - 1);
      final idx1 = (nextMs / durationMs * n).ceil().clamp(idx0 + 1, n);
      var peak = 0.0;
      for (var i = idx0; i < idx1; i++) {
        if (waveform[i] > peak) peak = waveform[i];
      }
      final bar = max(peak * maxBarH, 1.0);
      final alpha = t <= playedUntilMs ? 0.6 : 0.28;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x + _barStep / 2, midY),
            width: _barStep * 0.7,
            height: bar * 2,
          ),
          const Radius.circular(1),
        ),
        Paint()..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MixPainter old) =>
      now != old.now ||
      swapped != old.swapped ||
      window != old.window ||
      curve != old.curve ||
      bassSwap != old.bassSwap ||
      start != old.start ||
      cut != old.cut ||
      outWaveform != old.outWaveform ||
      inWaveform != old.inWaveform ||
      inDuration != old.inDuration ||
      outDuration != old.outDuration;
}
