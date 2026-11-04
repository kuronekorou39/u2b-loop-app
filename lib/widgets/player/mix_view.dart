import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/audio/sfx_library.dart';
import '../../core/audio/sfx_plan.dart';
import '../../core/audio/beat_grid.dart';
import '../../core/theme/app_theme.dart';
import '../loop/beat_lines.dart';

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
    this.outBeats,
    this.inBeats,
    this.inRatio = 1,
    this.beatError,
    this.sfxCues = const [],
    this.showCurves = true,
    this.linesOpacity = 1,
  });

  /// 音量曲線を描くか（デッキの板で切り替え。切替点の線と効果音の印は残す）
  final bool showCurves;

  /// 2 段をまたぐ線（音量曲線・切替点・ベーススワップ・効果音の印）の濃さ（0〜1）。
  /// 組が次へ進む演出で、先に消して最後に出す（[MixLanesAdvance]）。再生位置の線は含めない
  final double linesOpacity;

  /// 出る曲の時計 1ms あたり入る曲の時計が進む量（[MixPair.inRatio]）
  final double inRatio;

  /// 効果音の予定（出る曲の時計）。ライザーは始まりから切替点へ上がる線、インパクトは切替点の点
  final List<SfxCue> sfxCues;

  /// 効果音の印の色（拍の線・曲の色と区別がつく橙）
  static const sfxColor = Colors.orangeAccent;

  /// 交差中に測った拍のずれ（実時間 ms）。右上に数字で出す。null なら出さない
  final double? beatError;

  /// この範囲のずれなら「合っている」色（ms）
  static const beatErrorGoodMs = 15.0;
  static const beatErrorFairMs = 40.0;

  /// それぞれの曲の拍の線（格子と、小節頭の代わりの基準）。null なら引かない
  final BeatLineSource? outBeats;
  final BeatLineSource? inBeats;

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
          final body = GestureDetector(
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
                      outBeats: outBeats,
                      inBeats: inBeats,
                      inRatio: inRatio,
                      sfxCues: sfxCues,
                      showCurves: showCurves,
                      linesOpacity: linesOpacity,
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
                if (beatError case final err?)
                  Positioned(
                    top: 2,
                    right: 4,
                    child: _BeatErrorBadge(errorMs: err, style: laneLabel),
                  ),
              ],
            ),
          );
          return body;
        },
      ),
    );
  }
}

/// 実際に鳴っている 2 曲の拍のずれ（交差中に測ったもの）。線の見た目ではなく音のずれ
class _BeatErrorBadge extends StatelessWidget {
  const _BeatErrorBadge({required this.errorMs, required this.style});

  final double errorMs;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final abs = errorMs.abs();
    final color = abs <= MixView.beatErrorGoodMs
        ? AppTheme.accentGreen
        : abs <= MixView.beatErrorFairMs
            ? Colors.amber
            : AppTheme.accentRed;
    final sign = errorMs >= 0 ? '+' : '−';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('拍ずれ $sign${abs.round()}ms',
          style: style.copyWith(
              color: color, fontFeatures: const [FontFeature.tabularFigures()])),
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
    required this.outBeats,
    required this.inBeats,
    required this.inRatio,
    required this.sfxCues,
    required this.showCurves,
    required this.linesOpacity,
  });

  final List<SfxCue> sfxCues;
  final bool showCurves;
  final double linesOpacity;

  final double inRatio;

  final bool bassSwap;
  final BeatLineSource? outBeats;
  final BeatLineSource? inBeats;
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
      // 次曲は交差開始で inStart から鳴り始める（速度の比 inRatio で進む）
      toTrackMs: (t) => t < start.inMilliseconds
          ? null
          : inStart.inMilliseconds + (t - start.inMilliseconds) * inRatio,
      playedUntilMs: nowMs,
      color: AppTheme.pointBColor,
    );

    // 拍の線（1 拍目は濃く、数字は段の境目側）。それぞれの曲の時計で引く
    final outGrid = outBeats;
    if (outGrid != null) {
      BeatLines.paint(
        canvas,
        grid: outGrid.grid,
        anchorMs: outGrid.anchorMs,
        startMs: winStart,
        endMs: min(winEnd, cut.inMilliseconds.toDouble()),
        toX: toX,
        top: 0,
        bottom: laneH,
        color: Colors.white,
        numbers: true,
        numbersAtBottom: true,
      );
    }
    final inGrid = inBeats;
    if (inGrid != null) {
      // 次曲の時刻 = inStart + (旧曲の時計 − start) × inRatio
      final s0 = start.inMilliseconds.toDouble();
      final i0 = inStart.inMilliseconds.toDouble();
      double toIn(double t) => i0 + (t - s0) * inRatio;
      BeatLines.paint(
        canvas,
        grid: inGrid.grid,
        anchorMs: inGrid.anchorMs,
        startMs: toIn(max(winStart, s0)),
        endMs: toIn(winEnd),
        toX: (ms) => toX(s0 + (ms - i0) / inRatio),
        top: laneH,
        bottom: h,
        color: Colors.white,
        numbers: true,
      );
    }

    // 2 段をまたぐ線（音量曲線・切替点・ベーススワップ・効果音の印）。
    // 組が進む演出の間は薄く（層にまとめて濃さを掛ける）、0 なら描かない
    if (linesOpacity > 0) {
      final faded = linesOpacity < 1;
      if (faded) {
        canvas.saveLayer(
          Offset.zero & size,
          Paint()..color = Colors.white.withValues(alpha: linesOpacity),
        );
      }
      _drawCrossingLines(canvas,
          w: w, h: h, laneH: laneH, toX: toX, toT: toT, startX: startX, cutX: cutX);
      if (faded) canvas.restore();
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

  /// 2 段をまたぐ線。音量曲線（設定のつなぎ方、全高）は [showCurves] のときだけ
  void _drawCrossingLines(
    Canvas canvas, {
    required double w,
    required double h,
    required double laneH,
    required double Function(double tMs) toX,
    required double Function(double x) toT,
    required double startX,
    required double cutX,
  }) {
    if (showCurves) _drawCurves(canvas, w: w, h: h, toT: toT);

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

    _drawSfx(canvas, w: w, laneH: laneH, toX: toX, cutX: cutX);
  }

  void _drawCurves(
    Canvas canvas, {
    required double w,
    required double h,
    required double Function(double x) toT,
  }) {
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
  }

  /// 効果音の印。ライザー / スピンバックは始まりから切替点へ上がる（下がる）線、
  /// インパクトは切替点の上の点。どこで鳴るかを実機で確かめるためのもの
  void _drawSfx(Canvas canvas,
      {required double w,
      required double laneH,
      required double Function(double) toX,
      required double cutX}) {
    if (sfxCues.isEmpty) return;
    final paint = Paint()
      ..color = MixView.sfxColor.withValues(alpha: 0.85)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const top = 4.0;
    for (final cue in sfxCues) {
      final x0 = toX(cue.atMs);
      switch (cue.role) {
        case SfxRole.impact:
          if (x0 < -4 || x0 > w + 4) continue;
          canvas.drawCircle(Offset(x0, top + 2), 3.5, paint);
        case SfxRole.riser:
          if (cutX < 0 || x0 > w) continue;
          canvas.drawLine(Offset(x0, laneH), Offset(cutX, top), paint);
          // 始まりの足（小節頭に立つ）
          canvas.drawLine(Offset(x0, laneH - 4), Offset(x0, laneH + 4), paint);
        case SfxRole.spinback:
          if (cutX < 0 || x0 > w) continue;
          canvas.drawLine(Offset(x0, top), Offset(cutX, laneH), paint);
      }
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
      showCurves != old.showCurves ||
      linesOpacity != old.linesOpacity ||
      swapped != old.swapped ||
      window != old.window ||
      curve != old.curve ||
      bassSwap != old.bassSwap ||
      outBeats != old.outBeats ||
      inRatio != old.inRatio ||
      inBeats != old.inBeats ||
      !listEquals(sfxCues, old.sfxCues) ||
      start != old.start ||
      cut != old.cut ||
      outWaveform != old.outWaveform ||
      inWaveform != old.inWaveform ||
      inDuration != old.inDuration ||
      outDuration != old.outDuration;
}
