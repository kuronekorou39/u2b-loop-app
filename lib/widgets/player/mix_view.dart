import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/audio/crossfade_curve.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';

/// 曲の切り替わり前後の「ミックスビュー」。
///
/// 時間軸は旧曲の時計（切り替わる地点 [cut] を基準に前後 [lead] / [tail] 秒）。
/// 上段に旧曲の終わり側の波形、下段に次曲の頭の波形を同じ時間軸で縦に並べ、
/// その上に 2 本の音量曲線（旧曲は下がる・次曲は上がる、等パワー）と再生位置を重ねる。
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
    this.height = 72,
    this.curve = CrossfadeCurve.defaultCurve,
    this.bassSwap = false,
    this.onSeek,
  });

  /// タップ・横ドラッグで時間軸上の位置（旧曲の時計）を返す。null なら操作できない。
  /// 以前はジェスチャーが無く、交差の前後 8 秒ずつ + 交差中はシークの入口が無かった
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

  /// 切り替わり地点の前後に見せる長さ
  static const lead = Duration(seconds: 8);
  static const tail = Duration(seconds: 8);

  /// 幅 [width] のビューの x 座標を時間軸（旧曲の時計）に直す。
  /// 窓は start − [lead] 〜 cut + [tail]。端を超えた分は窓の端に丸める
  static Duration timeAtX(
    double x,
    double width, {
    required Duration start,
    required Duration cut,
  }) {
    final winStart = start - lead;
    final winEnd = cut + tail;
    if (width <= 0) return winStart;
    final p = (x / width).clamp(0.0, 1.0);
    return winStart + (winEnd - winStart) * p;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature('tnum')],
    );
    final laneLabel = textTheme.labelSmall!.copyWith(fontSize: 10);
    final untilCut = cut - now;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        children: [
          SizedBox(
            height: height,
            width: double.infinity,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final onSeek = this.onSeek;
                void seekAt(double x) => onSeek?.call(
                  timeAtX(x, constraints.maxWidth, start: start, cut: cut),
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: onSeek == null
                      ? null
                      : (d) => seekAt(d.localPosition.dx),
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
          ),
          SizedBox(
            height: 24,
            child: Row(
              children: [
                Icon(
                  Icons.swap_horiz,
                  size: AppIconSizes.xs,
                  color: Colors.grey.shade400,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text('ミックス ${(cut - start).inSeconds}s', style: labelStyle),
                const Spacer(),
                Text(
                  swapped
                      ? '切替から ${TimeUtils.formatShort(now - cut)}'
                      : untilCut.isNegative
                      ? '切替中'
                      : '切替まで ${TimeUtils.formatShort(untilCut)}',
                  style: labelStyle,
                ),
              ],
            ),
          ),
        ],
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
  final CrossfadeCurve curve;

  static const _barStep = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final laneH = h / 2;
    final winStart = (start - MixView.lead).inMilliseconds.toDouble();
    final winEnd = (cut + MixView.tail).inMilliseconds.toDouble();
    final span = max(1.0, winEnd - winStart);
    double toX(double tMs) => (tMs - winStart) / span * w;
    double toT(double x) => winStart + x / w * span;

    final startX = toX(start.inMilliseconds.toDouble());
    final cutX = toX(cut.inMilliseconds.toDouble());
    final nowMs = now.inMilliseconds.toDouble();
    final nowX = toX(nowMs);

    // 交差区間の背景
    canvas.drawRect(
      Rect.fromLTRB(startX, 0, cutX, h),
      Paint()..color = Colors.white.withValues(alpha: 0.05),
    );
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
    canvas.drawLine(
      Offset(cutX, 0),
      Offset(cutX, h),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );

    // ベーススワップの位置（点線）
    if (bassSwap && curve.bassSwapAt < 1) {
      final bx = startX + (cutX - startX) * curve.bassSwapAt;
      final paint = Paint()
        ..color = Colors.amber.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      for (var y = 0.0; y < h; y += 6) {
        canvas.drawLine(Offset(bx, y), Offset(bx, min(y + 3, h)), paint);
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
      final idx = (trackMs / durationMs * n).floor().clamp(0, n - 1);
      final bar = max(waveform[idx] * maxBarH, 1.0);
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
      curve != old.curve ||
      bassSwap != old.bassSwap ||
      start != old.start ||
      cut != old.cut ||
      outWaveform != old.outWaveform ||
      inWaveform != old.inWaveform ||
      inDuration != old.inDuration ||
      outDuration != old.outDuration;
}
