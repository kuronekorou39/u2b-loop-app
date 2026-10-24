import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// ジョグホイール（円盤）。デッキの板（[MixDeck]）に 2 つ並べる。
///
/// 回せる円盤（[JogWheel]）は入る曲の拍の位置（位相）を手で前後に動かす: 回すと [valueMs]
/// （入る曲の媒体ミリ秒、+ で曲を先へ）が増減し [onChanged] を呼ぶ（[touching] は
/// 指で回している間 true）。離すと [onChangeEnd]。1 周 = 1 拍（[periodMs]）。
/// 円盤の中心に今の量と拍のずれ（保存・戻すのボタンは板の側）。
/// DJ がプラッターの縁を押す／引く動き。拍の間隔（テンポ）はピッチフェーダー（[PitchFader]）
///
/// 表示だけの円盤（[JogWheel.platter]）は曲の再生に合わせて回る（レコードの回転）。
/// 触れても何も起きない（前曲は鳴っているので動かさない）。
///
/// 値（[valueMs]）は親（[jogOffsetProvider]）が持つ。このウィジェットは差分を返すだけ。
/// 1 本指の回転だけで操作する（2 本指のつまみは安定しないので使わない）
class JogWheel extends StatefulWidget {
  const JogWheel({
    super.key,
    required this.periodMs,
    required this.valueMs,
    required this.maxMs,
    required void Function(double valueMs, {required bool touching}) this.onChanged,
    required ValueChanged<double> this.onChangeEnd,
    this.errorMs,
    this.title = '次曲',
    this.size = 88,
  }) : turns = null;

  /// 表示だけの円盤。[turns] は回転数（再生位置から。1 = 1 周）
  const JogWheel.platter({
    super.key,
    required double this.turns,
    this.title = '前曲',
    this.size = 88,
  })  : periodMs = 0,
        valueMs = 0,
        maxMs = 0,
        onChanged = null,
        onChangeEnd = null,
        errorMs = null;

  /// 1 拍の長さ（媒体ミリ秒）。1 周でこの分だけ動く
  final double periodMs;

  /// 今の位置ずらし（媒体ミリ秒、+ で曲を先へ）
  final double valueMs;

  /// 動かせる幅（片側、媒体ミリ秒）
  final double maxMs;

  /// 回したとき。[touching] は指で回している間 true（離した瞬間に [onChangeEnd]）。
  /// null なら表示だけの円盤
  final void Function(double valueMs, {required bool touching})? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// 拍のずれ（実時間 ms、+ で入る曲が遅れている）。null なら出さない
  final double? errorMs;

  /// 表示だけの円盤の回転数。回せる円盤は [valueMs] から
  final double? turns;

  /// 円盤の中心に出す名前（動かしていないとき）
  final String title;

  /// 円盤の直径
  final double size;

  bool get readOnly => onChanged == null;

  /// レコードの回転（33⅓ rpm = 1 周 1.8 秒）。表示だけの円盤を再生位置で回すのに使う
  static double platterTurns(Duration position) =>
      position.inMilliseconds / 1800;

  @override
  State<JogWheel> createState() => _JogWheelState();
}

class _JogWheelState extends State<JogWheel> {
  /// 直前の指の角度（中心から見たラジアン）。回転量の差分を取るのに使う
  double? _lastAngle;

  double _angleOf(Offset local) {
    final c = widget.size / 2;
    return atan2(local.dy - c, local.dx - c);
  }

  void _onStart(DragStartDetails d) {
    _lastAngle = _angleOf(d.localPosition);
  }

  void _onUpdate(DragUpdateDetails d) {
    final last = _lastAngle;
    final a = _angleOf(d.localPosition);
    _lastAngle = a;
    if (last == null) return;
    // 角度の差（±π に丸める）。1 周 = 1 拍
    var da = a - last;
    if (da > pi) da -= 2 * pi;
    if (da < -pi) da += 2 * pi;
    final next = (widget.valueMs + da / (2 * pi) * widget.periodMs)
        .clamp(-widget.maxMs, widget.maxMs);
    widget.onChanged!(next, touching: true);
  }

  void _onEnd() {
    _lastAngle = null;
    widget.onChangeEnd!(widget.valueMs);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // 大きい円盤は中の文字も少し大きく
    final style = (widget.size >= 120 ? text.bodyMedium : text.labelSmall)!;
    final readOnly = widget.readOnly;
    final active = !readOnly && widget.valueMs.abs() >= 1;
    final turns = readOnly
        ? widget.turns!
        : widget.periodMs > 0
            ? widget.valueMs / widget.periodMs
            : 0.0;
    final disc = SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _WheelPainter(turns: turns, active: active),
        child: Center(
          child: Text(
            _centerLabel(),
            textAlign: TextAlign.center,
            style: style.copyWith(
              color: Colors.white,
              height: 1.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
    if (readOnly) {
      // 触れても何も起きない（鳴っている曲を動かさない）
      return AbsorbPointer(child: disc);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onStart,
      onPanUpdate: _onUpdate,
      onPanEnd: (_) => _onEnd(),
      onPanCancel: _onEnd,
      child: disc,
    );
  }

  /// 中心の文字。表示だけなら名前。回せる円盤は動かした量（+ は曲を先へ）と拍のずれ
  String _centerLabel() {
    if (widget.readOnly) return widget.title;
    final ms = widget.valueMs;
    final value = ms.abs() < 1
        ? widget.title
        : '${ms > 0 ? '+' : '−'}${ms.abs().round()}ms';
    final err = widget.errorMs;
    if (err == null) return value;
    return '$value\nずれ ${err >= 0 ? '+' : '−'}${err.abs().round()}';
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.turns, required this.active});

  /// 回転数（1 = 1 周）
  final double turns;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = min(size.width, size.height) / 2 - 2;

    // 円盤
    canvas.drawCircle(
      c,
      r,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: active ? 0.6 : 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // 回転につれて回る溝（レコードの溝）。向きと動きが見える
    final rot = turns * 2 * pi;
    final grooves = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    for (var i = 0; i < 12; i++) {
      final a = rot + i * pi / 6;
      canvas.drawLine(
        c + Offset(cos(a), sin(a)) * (r * 0.5),
        c + Offset(cos(a), sin(a)) * (r * 0.82),
        grooves,
      );
    }

    // 真上を基準にした目印。中心線がどれだけ回ったか
    final mark = -pi / 2 + rot;
    canvas.drawLine(
      c + Offset(cos(mark), sin(mark)) * (r * 0.5),
      c + Offset(cos(mark), sin(mark)) * (r * 0.86),
      Paint()
        ..color = active ? AppTheme.accentGreen : Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    // 12 時の固定の印（基準）
    canvas.drawCircle(
      c + Offset(0, -r),
      2.5,
      Paint()..color = Colors.white.withValues(alpha: 0.6),
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) =>
      turns != old.turns || active != old.active;
}
