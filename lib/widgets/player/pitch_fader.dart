import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// ピッチフェーダー（縦）。次曲のテンポ（拍の間隔）を、自動のテンポ合わせの速度から
/// ±[maxPercent] % 微調整する。DJ 機材のピッチフェーダーと同じ役割で、
/// 拍の位置（位相）はジョグホイール（[JogWheel]）が担う。
///
/// 上へ動かすと速く（+）、真ん中が曲本来のテンポ（0）。つまみは自動のテンポ合わせが置いた
/// 位置（[autoPercent]、緑の印）に手の微調整（[percent]）を足した所にあり、数字もその合計。
/// 自動の位置の近く（[snapPercent]）では自動の位置に吸い付く（微調整 0）。
/// つまみを押さえなくても、縦に動かせばその分だけ動く（細かく合わせやすい）。
/// 値（[percent]）は親（[tempoTrimProvider]）が持ち、このウィジェットは新しい微調整を返す。
/// 指で動かしている間は親の描き直しを待たず、返した値でつまみを描く
/// （親の描き直しが遅れても、つまみが指に付いてくる）。
/// [onChanged] が null なら表示だけ
class PitchFader extends StatefulWidget {
  const PitchFader({
    super.key,
    required this.percent,
    this.autoPercent = 0,
    this.maxPercent = 8,
    this.onChanged,
    this.onChangeEnd,
    this.height = 140,
    this.width = 48,
  });

  /// 今の手の微調整（±%、自動の位置からの差）
  final double percent;

  /// 自動のテンポ合わせが置いた位置（曲本来のテンポからの ±%）
  final double autoPercent;

  /// 動かせる幅（片側、%）
  final double maxPercent;

  /// 動かしたとき。null なら表示だけ
  final ValueChanged<double>? onChanged;

  /// 離したとき
  final ValueChanged<double>? onChangeEnd;

  final double height;
  final double width;

  /// 微調整がこれより小さければ 0 にする（自動の位置の溝）
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
    // 上へ動かすと + 。全長で ±max（つまみの位置 = 自動 + 手 が溝の中に収まる範囲）
    final auto = widget.autoPercent;
    var p = sp - (d.localPosition.dy - sd) / _travel * (2 * widget.maxPercent);
    p = p.clamp(-widget.maxPercent - auto, widget.maxPercent - auto);
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
    final trim = _shown;
    // つまみと数字は自動 + 手。手で動かしてあるときだけ緑
    final percent = widget.autoPercent + trim;
    final active = !readOnly && trim != 0;
    final fader = SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(
        painter: _FaderPainter(
          percent: percent,
          autoPercent: widget.autoPercent,
          maxPercent: widget.maxPercent,
          active: active,
          enabled: !readOnly,
        ),
      ),
    );
    // 値は溝の下（デッキの板で円盤の BPM の行と揃う）
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        const SizedBox(height: AppSpacing.xs),
        Text(
          PitchFader.label(percent),
          // 列が狭くても 1 行（折り返すと BPM の行と揃わない）
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style.copyWith(
              color: active ? AppTheme.accentGreen : Colors.white),
        ),
      ],
    );
  }
}

class _FaderPainter extends CustomPainter {
  _FaderPainter({
    required this.percent,
    required this.autoPercent,
    required this.maxPercent,
    required this.active,
    required this.enabled,
  });

  /// つまみの位置（自動 + 手、±%）
  final double percent;

  /// 自動のテンポ合わせの位置（緑の印）
  final double autoPercent;
  final double maxPercent;
  final bool active;
  final bool enabled;

  /// 印の横幅（つまみの両脇に出る）
  static const _markHalf = 17.0;

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
    // 自動のテンポ合わせの位置（つまみの両脇に出る短い緑の線。つまみが乗っていても見える）
    final autoY = (top + travel / 2 - autoPercent / maxPercent * travel / 2)
        .clamp(top, bottom);
    final mark = Paint()
      ..color = AppTheme.accentGreen.withValues(alpha: enabled ? 0.9 : 0.5)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx - _markHalf, autoY), Offset(cx - 13, autoY), mark);
    canvas.drawLine(Offset(cx + 13, autoY), Offset(cx + _markHalf, autoY), mark);
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
      autoPercent != old.autoPercent ||
      maxPercent != old.maxPercent ||
      active != old.active ||
      enabled != old.enabled;
}
