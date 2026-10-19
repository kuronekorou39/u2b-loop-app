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
/// その一部（[window]）を描く。上段に旧曲の波形、下段に次曲の波形を同じ時間軸で縦に並べ、
/// その上に 2 本の音量曲線（旧曲は下がる・次曲は上がる）と再生位置を重ねる。
///
/// 操作: 帯の上のタップ・ドラッグはシーク（[onSeek]）だけ。拡大縮小は「−」「＋」と
/// 範囲のピル「交差」「前後」「全体」、見る場所は帯の下の細い全体バー（ミニマップ）を
/// ドラッグしてずらす（[onWindowChanged]）。2 本指のつまみは細い帯では安定しないので使わない。
/// 再生位置が窓の外に出ても追いかけず、端に「現在地へ」の矢印を出す
class MixView extends StatefulWidget {
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
    required this.timelineEnd,
    this.onWindowChanged,
    this.prepLine,
    this.height = 72,
    this.curve = CrossfadeCurve.defaultCurve,
    this.bassSwap = false,
    this.onSeek,
  });

  /// 見えている範囲（旧曲の時計）。親が持ち、[onWindowChanged] で更新する
  final MixWindow window;

  /// 時間軸の終わり（2 曲目の終わりを旧曲の時計に直したもの）。頭は 0
  final Duration timelineEnd;

  /// 「−」「＋」、範囲のピル、「現在地へ」やミニマップのドラッグで窓が変わったとき
  final ValueChanged<MixWindow>? onWindowChanged;

  /// 準備線（旧曲の時計）。ここから右は次のつなぎの準備に入る（前曲には戻れない）ので、
  /// 次曲の波形を薄くして線を引く。null なら描かない
  final Duration? prepLine;

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

  /// 最初に見せる範囲: 切り替わり地点の前後（切り替え付近を何度も聴けるよう広めに取る）
  static const lead = Duration(seconds: 16);
  static const tail = Duration(seconds: 16);

  /// 最も寄せたときの窓の幅の下限（交差がこれより短くても、これより寄せない）
  static const minSpanFloor = Duration(seconds: 2);

  /// 最も寄せたときの窓の幅: 交差（start〜cut）がちょうど画面幅になる
  static Duration minSpan(Duration start, Duration cut) {
    final fade = cut - start;
    return fade < minSpanFloor ? minSpanFloor : fade;
  }

  /// 窓を時間軸（0〜[timelineEnd]）と幅の下限に収める
  static MixWindow clampWindow(
    MixWindow w, {
    required Duration minSpan,
    required Duration timelineEnd,
  }) {
    var span = w.span < minSpan ? minSpan : w.span;
    if (span > timelineEnd) span = timelineEnd;
    var s = w.start;
    if (s + span > timelineEnd) s = timelineEnd - span;
    if (s < Duration.zero) s = Duration.zero;
    return MixWindow(s, s + span);
  }

  /// 最初の窓: 切替点の前後 [lead] / [tail]
  static MixWindow initialWindow({
    required Duration start,
    required Duration cut,
    required Duration timelineEnd,
  }) =>
      clampWindow(MixWindow(start - lead, cut + tail),
          minSpan: minSpan(start, cut), timelineEnd: timelineEnd);

  /// 「交差」: 重なりがぴったり画面幅
  static MixWindow crossfadeWindow({
    required Duration start,
    required Duration cut,
    required Duration timelineEnd,
  }) {
    final span = minSpan(start, cut);
    final mid = start + (cut - start) ~/ 2;
    return clampWindow(MixWindow(mid - span ~/ 2, mid + span ~/ 2),
        minSpan: span, timelineEnd: timelineEnd);
  }

  /// 「全体」: 1 曲目の頭から 2 曲目の終わりまで
  static MixWindow wholeWindow(Duration timelineEnd) =>
      MixWindow(Duration.zero, timelineEnd);

  /// 「−」「＋」の 1 段ぶんの倍率
  static const zoomStep = 2.0;

  /// 幅を [factor] 倍にする（[around] の時刻を動かさない。窓の外なら真ん中を基準に）
  static MixWindow zoomed(
    MixWindow w,
    double factor, {
    required Duration around,
    required Duration minSpan,
    required Duration timelineEnd,
  }) {
    final spanMs = w.span.inMilliseconds * factor;
    final anchor = w.contains(around) ? around : w.start + w.span ~/ 2;
    final p = w.span.inMilliseconds <= 0
        ? 0.5
        : (anchor - w.start).inMilliseconds / w.span.inMilliseconds;
    final startMs = anchor.inMilliseconds - spanMs * p;
    return clampWindow(
      MixWindow(Duration(milliseconds: startMs.round()),
          Duration(milliseconds: (startMs + spanMs).round())),
      minSpan: minSpan,
      timelineEnd: timelineEnd,
    );
  }

  /// 「現在地へ」: 幅はそのまま、[now] が真ん中に来る窓
  static MixWindow centeredOn(
    Duration now, {
    required Duration span,
    required Duration minSpan,
    required Duration timelineEnd,
  }) =>
      clampWindow(MixWindow(now - span ~/ 2, now + span ~/ 2),
          minSpan: minSpan, timelineEnd: timelineEnd);

  /// 幅 [width] のビューの x 座標を時間軸（旧曲の時計）に直す。端を超えた分は窓の端に丸める
  static Duration timeAtX(double x, double width, {required MixWindow window}) {
    if (width <= 0) return window.start;
    final p = (x / width).clamp(0.0, 1.0);
    return window.start + window.span * p;
  }

  @override
  State<MixView> createState() => _MixViewState();
}

class _MixViewState extends State<MixView> {
  Duration get _minSpan => MixView.minSpan(widget.start, widget.cut);

  void _changeWindow(MixWindow w) => widget.onWindowChanged?.call(
        MixView.clampWindow(w,
            minSpan: _minSpan, timelineEnd: widget.timelineEnd),
      );

  void _zoom(double factor) => _changeWindow(MixView.zoomed(
        widget.window,
        factor,
        around: widget.now,
        minSpan: _minSpan,
        timelineEnd: widget.timelineEnd,
      ));

  /// ミニマップ: 押した・ドラッグした位置が窓の真ん中に来るようにずらす（幅はそのまま）
  void _panTo(Duration t) => _changeWindow(MixView.centeredOn(
        t,
        span: widget.window.span,
        minSpan: _minSpan,
        timelineEnd: widget.timelineEnd,
      ));

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final labelStyle = textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature('tnum')],
    );
    final laneLabel = textTheme.labelSmall!;
    final w = widget;
    final window = w.window;
    final nowOutside = !window.contains(w.now);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        children: [
          SizedBox(
            height: w.height,
            width: double.infinity,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final onSeek = w.onSeek;
                void seekAt(double x) => onSeek?.call(
                    MixView.timeAtX(x, constraints.maxWidth, window: window));
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
                            outWaveform: w.outWaveform,
                            outDuration: w.outDuration,
                            inWaveform: w.inWaveform,
                            inDuration: w.inDuration,
                            inStart: w.inStart,
                            start: w.start,
                            cut: w.cut,
                            now: w.now,
                            swapped: w.swapped,
                            window: window,
                            curve: w.curve,
                            bassSwap: w.bassSwap,
                            prepLine: w.prepLine,
                            prepLabelStyle: laneLabel.copyWith(
                              color: Colors.white.withValues(alpha: 0.7),
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 4)
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 4,
                        top: 2,
                        right: 4,
                        child: _LaneLabel(
                          text: w.outTitle,
                          color: AppTheme.pointAColor,
                          style: laneLabel,
                        ),
                      ),
                      Positioned(
                        left: 4,
                        bottom: 2,
                        right: 4,
                        child: _LaneLabel(
                          text: '次: ${w.inTitle}',
                          color: AppTheme.pointBColor,
                          style: laneLabel,
                        ),
                      ),
                      // 再生位置が窓の外: その側の端に「現在地へ」
                      if (nowOutside && w.onWindowChanged != null)
                        Positioned(
                          left: w.now < window.start ? 4 : null,
                          right: w.now > window.end ? 4 : null,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _JumpToNowChip(
                              left: w.now < window.start,
                              onTap: () => _changeWindow(MixView.centeredOn(
                                w.now,
                                span: window.span,
                                minSpan: _minSpan,
                                timelineEnd: w.timelineEnd,
                              )),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (w.onWindowChanged != null) ...[
            const SizedBox(height: AppSpacing.xs),
            _MiniMap(
              window: window,
              timelineEnd: w.timelineEnd,
              start: w.start,
              cut: w.cut,
              now: w.now,
              onPanTo: _panTo,
            ),
          ],
          // 範囲のピル（今の窓がどれかを明るく）と「−」「＋」。説明文は置かない
          if (w.onWindowChanged != null)
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  _RangePill(
                    style: labelStyle,
                    options: [
                      (
                        label: '交差',
                        tooltip: '重なっている部分を画面幅いっぱいに',
                        window: MixView.crossfadeWindow(
                          start: w.start,
                          cut: w.cut,
                          timelineEnd: w.timelineEnd,
                        ),
                      ),
                      (
                        label: '前後',
                        tooltip: '切り替わりの前後 16 秒',
                        window: MixView.initialWindow(
                          start: w.start,
                          cut: w.cut,
                          timelineEnd: w.timelineEnd,
                        ),
                      ),
                      (
                        label: '全体',
                        tooltip: '1 曲目の頭から 2 曲目の終わりまで',
                        window: MixView.wholeWindow(w.timelineEnd),
                      ),
                    ],
                    current: window,
                    onSelect: _changeWindow,
                  ),
                  const Spacer(),
                  _ZoomIconButton(
                    icon: Icons.remove,
                    tooltip: '縮小',
                    onTap: window.span >= w.timelineEnd
                        ? null
                        : () => _zoom(MixView.zoomStep),
                  ),
                  _ZoomIconButton(
                    icon: Icons.add,
                    tooltip: '拡大',
                    onTap: window.span <= _minSpan
                        ? null
                        : () => _zoom(1 / MixView.zoomStep),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 範囲の選択。黒い地の上に候補を並べ、今の窓と同じものを緑で明るくする
/// （どれでもない途中の窓なら、どれも明るくしない）
class _RangePill extends StatelessWidget {
  const _RangePill({
    required this.style,
    required this.options,
    required this.current,
    required this.onSelect,
  });

  final TextStyle? style;
  final List<({String label, String tooltip, MixWindow window})> options;
  final MixWindow current;
  final ValueChanged<MixWindow> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            Tooltip(
              message: o.tooltip,
              child: InkWell(
                onTap: () => onSelect(o.window),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: 2),
                  decoration: o.window == current
                      ? ShapeDecoration(
                          shape: const StadiumBorder(),
                          color: AppTheme.accentGreen.withValues(alpha: 0.22),
                        )
                      : null,
                  child: Text(
                    o.label,
                    style: style?.copyWith(
                      color: o.window == current
                          ? AppTheme.accentGreen
                          : AppTheme.muted(context),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ZoomIconButton extends StatelessWidget {
  const _ZoomIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? AppTheme.muted(context, alpha: 0.35)
        : AppTheme.accentGreen;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Icon(icon, size: AppIconSizes.sm, color: color),
        ),
      ),
    );
  }
}

/// 帯の下の細い全体バー: 1 曲目の頭から 2 曲目の終わりまでを描き、
/// 見えている範囲（窓）を明るい箱で示す。押す・ドラッグで窓をそこへずらす
class _MiniMap extends StatelessWidget {
  const _MiniMap({
    required this.window,
    required this.timelineEnd,
    required this.start,
    required this.cut,
    required this.now,
    required this.onPanTo,
  });

  final MixWindow window;
  final Duration timelineEnd;
  final Duration start;
  final Duration cut;
  final Duration now;
  final ValueChanged<Duration> onPanTo;

  static const height = 10.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          void panAt(double x) {
            if (timelineEnd <= Duration.zero || width <= 0) return;
            onPanTo(timelineEnd * (x / width).clamp(0.0, 1.0));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => panAt(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => panAt(d.localPosition.dx),
            child: CustomPaint(
              painter: _MiniMapPainter(
                window: window,
                timelineEnd: timelineEnd,
                start: start,
                cut: cut,
                now: now,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  _MiniMapPainter({
    required this.window,
    required this.timelineEnd,
    required this.start,
    required this.cut,
    required this.now,
  });

  final MixWindow window;
  final Duration timelineEnd;
  final Duration start;
  final Duration cut;
  final Duration now;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final totalMs = max(1, timelineEnd.inMilliseconds);
    double toX(Duration t) => (t.inMilliseconds / totalMs).clamp(0.0, 1.0) * w;
    final r = Radius.circular(h / 2);

    // 全体の下地
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), r),
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );
    // 交差の位置
    canvas.drawRect(
      Rect.fromLTRB(toX(start), 0, max(toX(cut), toX(start) + 2), h),
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );
    // 窓
    final winRect = Rect.fromLTRB(
        toX(window.start), 0, max(toX(window.end), toX(window.start) + 6), h);
    canvas.drawRRect(
      RRect.fromRectAndRadius(winRect, r),
      Paint()..color = AppTheme.accentGreen.withValues(alpha: 0.35),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(winRect, r),
      Paint()
        ..color = AppTheme.accentGreen.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    // 再生位置
    final nx = toX(now);
    canvas.drawLine(
      Offset(nx, 0),
      Offset(nx, h),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter old) =>
      window != old.window ||
      timelineEnd != old.timelineEnd ||
      start != old.start ||
      cut != old.cut ||
      now != old.now;
}

/// 再生位置が窓の外にあるとき、その側の端に出す「現在地へ」
class _JumpToNowChip extends StatelessWidget {
  const _JumpToNowChip({required this.left, required this.onTap});

  final bool left;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    final icon = Icon(
      left ? Icons.keyboard_double_arrow_left : Icons.keyboard_double_arrow_right,
      size: AppIconSizes.xs,
      color: Colors.white,
    );
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (left) icon,
              Text('現在地',
                  style: style?.copyWith(color: Colors.white)),
              if (!left) icon,
            ],
          ),
        ),
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
    required this.prepLine,
    required this.prepLabelStyle,
  });

  final bool bassSwap;
  final Duration? prepLine;
  final TextStyle prepLabelStyle;
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

    // 交差区間の背景
    canvas.drawRect(
      Rect.fromLTRB(max(0, startX), 0, min(w, cutX), h),
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
    final prepMs = prepLine?.inMilliseconds.toDouble();
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
      // 準備線より右は薄く（この組を抜ける範囲）
      fadedFromMs: prepMs,
    );

    // 準備線（点線）と「次のつなぎへ」
    if (prepMs != null && prepMs > winStart && prepMs < winEnd) {
      final px = toX(prepMs);
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      for (var y = 0.0; y < h; y += 6) {
        canvas.drawLine(Offset(px, y), Offset(px, min(y + 3, h)), paint);
      }
      final label = TextPainter(
        text: TextSpan(text: '次のつなぎへ', style: prepLabelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      // 右に余白があれば線の右、無ければ左に
      final fitsRight = px + 4 + label.width <= w;
      label.paint(
        canvas,
        Offset(fitsRight ? px + 4 : px - 4 - label.width, laneH + 2),
      );
    }

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
    double? fadedFromMs,
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
      var alpha = t <= playedUntilMs ? 0.6 : 0.28;
      if (fadedFromMs != null && t >= fadedFromMs) alpha *= 0.4;
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
      prepLine != old.prepLine ||
      start != old.start ||
      cut != old.cut ||
      outWaveform != old.outWaveform ||
      inWaveform != old.inWaveform ||
      inDuration != old.inDuration ||
      outDuration != old.outDuration;
}
