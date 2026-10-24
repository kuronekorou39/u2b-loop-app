import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// ピッチフェーダー（縦）。次曲のテンポ（拍の間隔）を、自動のテンポ合わせの速度から
/// ±[maxPercent] % 微調整する。DJ 機材のピッチフェーダーと同じ役割で、
/// 拍の位置（位相）はジョグホイール（[JogWheel]）が担う。
///
/// 上へ動かすと速く（+）、真ん中が 0。0 の近く（[snapPercent]）では 0 に吸い付く。
/// つまみを押さえなくても、縦に動かせばその分だけ動く（細かく合わせやすい）。
/// 値（[percent]）は親（[tempoTrimProvider]）が持ち、このウィジェットは新しい値を返す。
/// 指で動かしている間は親の描き直しを待たず、返した値でつまみを描く
/// （親の描き直しが遅れても、つまみが指に付いてくる）。
/// [onChanged] が null なら表示だけ
class PitchFader extends StatefulWidget {
  const PitchFader({
    super.key,
    required this.percent,
    this.maxPercent = 8,
    this.onChanged,
    this.onChangeEnd,
    this.height = 140,
    this.width = 48,
  });

  /// 今の微調整（±%）
  final double percent;

  /// 動かせる幅（片側、%）
  final double maxPercent;

  /// 動かしたとき。null なら表示だけ
  final ValueChanged<double>? onChanged;

  /// 離したとき
  final ValueChanged<double>? onChangeEnd;

  final double height;
  final double width;

  /// これより 0 に近ければ 0 にする（真ん中の溝）
  static const snapPercent = 0.15;

  /// つまみの高さの半分（溝の両端の余白）
  static const knobHalf = 7.0;

  bool get readOnly => onChanged == null;

  /// 表示用の文字（'+0.3%' / '−1.2%' / '0'）
  static String label(double percent) {
    if (percent.abs() < 0.05) return '0';
    return '${percent > 0 ? '+' : '−'}${percent.abs().toStringAsFixed(1)}%';
  }

  @override
  State<PitchFader> createState() => _PitchFaderState();
}

class _PitchFaderState extends State<PitchFader> {
  double? _startPercent;
  double? _startDy;

  /// 指で動かしている間の値（離したら親の値に戻る）
  double? _dragPercent;

  double get _shown => _dragPercent ?? widget.percent;

  /// つまみが動ける長さ
  double get _travel => widget.height - PitchFader.knobHalf * 2;

  void _onStart(DragStartDetails d) {
    _startPercent = widget.percent;
    _startDy = d.localPosition.dy;
  }

  void _onUpdate(DragUpdateDetails d) {
    final sp = _startPercent;
    final sd = _startDy;
    if (sp == null || sd == null) return;
    // 上へ動かすと + 。全長で ±max
    var p = sp - (d.localPosition.dy - sd) / _travel * (2 * widget.maxPercent);
    p = p.clamp(-widget.maxPercent, widget.maxPercent);
    if (p.abs() < PitchFader.snapPercent) p = 0;
    setState(() => _dragPercent = p);
    widget.onChanged!(p);
  }

  void _onEnd() {
    final last = _dragPercent ?? widget.percent;
    _startPercent = null;
    _startDy = null;
    setState(() => _dragPercent = null);
    widget.onChangeEnd?.call(last);
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall!.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    final readOnly = widget.readOnly;
    final percent = _shown;
    final active = !readOnly && percent != 0;
    final fader = SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(
        painter: _FaderPainter(
          percent: percent,
          maxPercent: widget.maxPercent,
          active: active,
          enabled: !readOnly,
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          PitchFader.label(percent),
          style: style.copyWith(
              color: active ? AppTheme.accentGreen : Colors.white),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (readOnly)
          AbsorbPointer(child: fader)
        else
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: _onStart,
            onVerticalDragUpdate: _onUpdate,
            onVerticalDragEnd: (_) => _onEnd(),
            onVerticalDragCancel: _onEnd,
            child: fader,
          ),
      ],
    );
  }
}

class _FaderPainter extends CustomPainter {
  _FaderPainter({
    required this.percent,
    required this.maxPercent,
    required this.active,
    required this.enabled,
  });

  final double percent;
  final double maxPercent;
  final bool active;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final top = PitchFader.knobHalf;
    final bottom = size.height - PitchFader.knobHalf;
    final travel = bottom - top;
    final dim = Colors.white.withValues(alpha: enabled ? 0.35 : 0.2);

    // 溝
    canvas.drawLine(
      Offset(cx, top),
      Offset(cx, bottom),
      Paint()
        ..color = dim
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    // 目盛り: 1% ごと。0 と両端は長く
    final ticks = maxPercent.round();
    for (var i = -ticks; i <= ticks; i++) {
      final y = top + travel / 2 - i / maxPercent * travel / 2;
      final long = i == 0 || i.abs() == ticks;
      final half = long ? 9.0 : 4.0;
      canvas.drawLine(
        Offset(cx - half, y),
        Offset(cx + half, y),
        Paint()
          ..color = i == 0 ? Colors.white.withValues(alpha: 0.7) : dim
          ..strokeWidth = i == 0 ? 2 : 1,
      );
    }
    // つまみ
    final y = top + travel / 2 - percent / maxPercent * travel / 2;
    final knob = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, y), width: 26, height: PitchFader.knobHalf * 2),
      const Radius.circular(4),
    );
    canvas.drawRRect(knob, Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.drawRRect(
      knob,
      Paint()
        ..color = active
            ? AppTheme.accentGreen
            : Colors.white.withValues(alpha: enabled ? 0.8 : 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // つまみの中の線（指で合わせる印）
    canvas.drawLine(
      Offset(cx - 9, y),
      Offset(cx + 9, y),
      Paint()
        ..color = active ? AppTheme.accentGreen : Colors.white.withValues(alpha: 0.8)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _FaderPainter old) =>
      percent != old.percent ||
      maxPercent != old.maxPercent ||
      active != old.active ||
      enabled != old.enabled;
}
