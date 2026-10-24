import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'mix_view.dart';

/// ジョグホイール（円盤）。重ね表示の入る曲の拍を手で前後に動かす。
///
/// 回すと [valueMs]（入る曲の媒体ミリ秒、+ で曲を先へ）が増減し、[onChanged] を呼ぶ
/// （[touching] が true の間は指で回している）。離すと [onChangeEnd]。
/// 1 周 = 1 拍ぶん（[periodMs]）。中心に今の量、下に拍のずれと「保存 / 戻す」。
///
/// 値（[valueMs]）は親（[jogOffsetProvider]）が持つ。このウィジェットは差分を返すだけ。
/// 1 本指の回転だけで操作する（2 本指のつまみは細い帯では安定しないので使わない）
class JogWheel extends StatefulWidget {
  const JogWheel({
    super.key,
    required this.periodMs,
    required this.valueMs,
    required this.maxMs,
    required this.onChanged,
    required this.onChangeEnd,
    this.errorMs,
    this.onSave,
    this.onReset,
    this.size = 72,
  });

  /// 1 拍の長さ（媒体ミリ秒）。1 周でこの分だけ動く
  final double periodMs;

  /// 今の位置ずらし（媒体ミリ秒、+ で曲を先へ）
  final double valueMs;

  /// 動かせる幅（片側、媒体ミリ秒）
  final double maxMs;

  /// 回したとき。[touching] は指で回している間 true（離した瞬間に [onChangeEnd]）
  final void Function(double valueMs, {required bool touching}) onChanged;
  final ValueChanged<double> onChangeEnd;

  /// 拍のずれ（実時間 ms、+ で入る曲が遅れている）。null なら出さない
  final double? errorMs;

  /// 保存（拍の格子に焼き込む）。動かしていなければ null で無効
  final VoidCallback? onSave;

  /// 真ん中（0）に戻す。動かしていなければ null で無効
  final VoidCallback? onReset;

  final double size;

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
    widget.onChanged(next, touching: true);
  }

  void _onEnd() {
    _lastAngle = null;
    widget.onChangeEnd(widget.valueMs);
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall!;
    final turns = widget.periodMs > 0 ? widget.valueMs / widget.periodMs : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _onStart,
          onPanUpdate: _onUpdate,
          onPanEnd: (_) => _onEnd(),
          onPanCancel: _onEnd,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(
              painter: _WheelPainter(
                turns: turns,
                active: widget.valueMs.abs() >= 1,
              ),
              child: Center(
                child: Text(
                  _centerLabel(widget.valueMs),
                  textAlign: TextAlign.center,
                  style: style.copyWith(
                    color: Colors.white,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          height: 14,
          child: widget.errorMs == null
              ? null
              : Text(
                  _errorLabel(widget.errorMs!),
                  style: style.copyWith(
                    color: _errorColor(widget.errorMs!),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: '真ん中に戻す',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onReset,
            ),
            IconButton(
              icon: const Icon(Icons.push_pin_outlined, size: 18),
              tooltip: 'この曲の拍の位置に保存',
              visualDensity: VisualDensity.compact,
              color: AppTheme.accentGreen,
              onPressed: widget.onSave,
            ),
          ],
        ),
      ],
    );
  }

  /// 中心の数字（動かした量）。+ は曲を先へ
  static String _centerLabel(double ms) {
    if (ms.abs() < 1) return '拍\nジョグ';
    final sign = ms > 0 ? '+' : '−';
    return '$sign${ms.abs().round()}\nms';
  }

  static String _errorLabel(double err) {
    final sign = err >= 0 ? '+' : '−';
    return 'ずれ $sign${err.abs().round()}ms';
  }

  static Color _errorColor(double err) {
    final abs = err.abs();
    if (abs <= MixView.beatErrorGoodMs) return AppTheme.accentGreen;
    if (abs <= MixView.beatErrorFairMs) return Colors.amber;
    return AppTheme.accentRed;
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.turns, required this.active});

  /// 回した回転数（1 = 1 拍 = 1 周）
  final double turns;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = min(size.width, size.height) / 2 - 2;

    // 外周
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: active ? 0.5 : 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // 回転につれて回る溝（レコードの溝）。向きで動きが見える
    final rot = turns * 2 * pi;
    final grooves = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (var i = 0; i < 12; i++) {
      final a = rot + i * pi / 6;
      canvas.drawLine(
        c + Offset(cos(a), sin(a)) * (r * 0.45),
        c + Offset(cos(a), sin(a)) * (r * 0.8),
        grooves,
      );
    }

    // 真上を基準にした目印（12 時）。中心線がどれだけ回ったか
    final mark = -pi / 2 + rot;
    canvas.drawLine(
      c,
      c + Offset(cos(mark), sin(mark)) * (r * 0.82),
      Paint()
        ..color = active ? AppTheme.accentGreen : Colors.white.withValues(alpha: 0.6)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    // 12 時の固定の印（基準）
    canvas.drawCircle(
      c + Offset(0, -r),
      2,
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) =>
      turns != old.turns || active != old.active;
}
