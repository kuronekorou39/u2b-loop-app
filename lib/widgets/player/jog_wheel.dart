import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';

/// ジョグホイール（円盤）。デッキの板（[MixDeck]）に 2 つ並べる。
///
/// 回せる円盤（[JogWheel]）は入る曲の拍の位置（位相）を手で前後に動かす: 回すと [valueMs]
/// （入る曲の媒体ミリ秒、+ で曲を先へ）が増減し [onChanged] を呼ぶ（[touching] は
/// 指で回している間 true）。離すと [onChangeEnd]。1 周 = 1 拍（[periodMs]）。
/// 円盤の中心は色の点、動かしていれば量（保存・戻すのボタンは板の側）。
/// 速く回すほど大きく進み（[maxGain] 倍まで）、はじくと勢いで滑ってだんだん止まる。
/// 動かさずに長押しすると微調整（[fineGain] 倍。軽く振動して知らせる）。
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
    this.color = AppTheme.pointBColor,
    this.size = 88,
  }) : turns = null;

  /// 表示だけの円盤。[turns] は回転数（再生位置から。1 = 1 周）
  const JogWheel.platter({
    super.key,
    required double this.turns,
    this.color = AppTheme.pointAColor,
    this.size = 88,
  })  : periodMs = 0,
        valueMs = 0,
        maxMs = 0,
        onChanged = null,
        onChangeEnd = null;

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

  /// 表示だけの円盤の回転数。回せる円盤は [valueMs] から
  final double? turns;

  /// 円盤の中心の点の色（重ね表示の段の色: 前曲は赤、次曲は青）。
  /// 以前は「前曲」「次曲」の文字だった
  final Color color;

  /// 円盤の直径
  final double size;

  bool get readOnly => onChanged == null;

  /// この速さ（ラジアン/秒）を超えて回すと、速いほど大きく進む
  static const accelFrom = 6.0;

  /// 速く回したときの最大の倍率
  static const maxGain = 4.0;

  /// 長押しの微調整の倍率と、入るまでの長さ
  static const fineGain = 0.2;
  static const holdForFine = Duration(milliseconds: 500);

  /// はじいて滑らせる最低の速さ（ラジアン/秒）と、滑りの止まりやすさ（1/秒）
  static const glideFrom = 5.0;
  static const friction = 3.0;

  /// レコードの回転（33⅓ rpm = 1 周 1.8 秒）。表示だけの円盤を再生位置で回すのに使う
  static double platterTurns(Duration position) =>
      position.inMilliseconds / 1800;

  @override
  State<JogWheel> createState() => _JogWheelState();
}

class _JogWheelState extends State<JogWheel>
    with SingleTickerProviderStateMixin {
  /// 直前の指の角度（中心から見たラジアン）。回転量の差分を取るのに使う
  double? _lastAngle;

  /// 直前の指の動きの時刻（回す速さを測る。指の動きに付いた時刻）
  Duration? _lastTime;

  /// 直前の指の動きを受けた時刻（離したときに勢いが新しいか見る）
  final _clock = Stopwatch()..start();
  Duration? _lastSeen;

  /// 操作中の値（親の値は 1 フレーム遅れて戻るので、手元で積む）
  double _value = 0;

  /// 回す速さ（ラジアン/秒、符号つき。はじいたときの勢いに使う）
  double _omega = 0;

  /// 長押しで入る微調整
  bool _fine = false;

  /// はじいた後の滑り
  late final Ticker _glide = createTicker(_onGlide);
  Duration? _glideLast;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _glide.dispose();
    super.dispose();
  }

  double _angleOf(Offset local) {
    final c = widget.size / 2;
    return atan2(local.dy - c, local.dx - c);
  }

  /// 回す速さ（ラジアン/秒）から倍率。ゆっくりなら 1 倍、速く回すほど大きく
  static double _gainFor(double speed) =>
      (1 + max(0.0, speed - JogWheel.accelFrom) / JogWheel.accelFrom)
          .clamp(1.0, JogWheel.maxGain);

  /// 角度 [da] だけ回した分を値に足して知らせる。動かせる端に着いたら true
  bool _apply(double da, double gain) {
    final next = (_value + da / (2 * pi) * widget.periodMs * gain)
        .clamp(-widget.maxMs, widget.maxMs);
    final hitEnd = next == _value && da != 0;
    _value = next;
    widget.onChanged!(next, touching: true);
    return hitEnd;
  }

  /// 指を置いた位置。ドラッグと判定された時点の位置から測ると、判定までの
  /// 動き（遊びの分）が捨てられる
  Offset? _downAt;

  void _begin(Offset local, Duration? at) {
    if (_glide.isActive) _glide.stop();
    _lastAngle = _angleOf(_downAt ?? local);
    _lastTime = at;
    _lastSeen = _clock.elapsed;
    _value = widget.valueMs;
    _omega = 0;
  }

  void _move(Offset local, Duration? at) {
    final last = _lastAngle;
    final a = _angleOf(local);
    _lastAngle = a;
    final prev = _lastTime;
    final dt = prev == null || at == null
        ? 0.016
        : max(0.004, (at - prev).inMicroseconds / 1e6);
    _lastTime = at;
    _lastSeen = _clock.elapsed;
    if (last == null) return;
    // 角度の差（±π に丸める）
    var da = a - last;
    if (da > pi) da -= 2 * pi;
    if (da < -pi) da += 2 * pi;
    // 速さはならして持つ（指のぶれで勢いが跳ねないように）
    _omega = _omega * 0.6 + (da / dt) * 0.4;
    _apply(da, _fine ? JogWheel.fineGain : _gainFor(_omega.abs()));
  }

  void _finish({required bool allowGlide}) {
    _lastAngle = null;
    final wasFine = _fine;
    if (_fine) setState(() => _fine = false);
    // 最後の動きが新しく、勢いがあれば滑らせる
    final fresh = _lastSeen != null &&
        (_clock.elapsed - _lastSeen!).inMilliseconds < 80;
    if (allowGlide &&
        !wasFine &&
        fresh &&
        _omega.abs() > JogWheel.glideFrom) {
      _glideLast = null;
      _glide.start();
      return;
    }
    widget.onChangeEnd!(_value);
  }

  void _onGlide(Duration elapsed) {
    final last = _glideLast;
    _glideLast = elapsed;
    if (last == null) return;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    // だんだん止まる（摩擦）
    _omega *= exp(-JogWheel.friction * dt);
    final hitEnd = _apply(_omega * dt, _gainFor(_omega.abs()));
    if (hitEnd || _omega.abs() < 0.4) {
      _glide.stop();
      widget.onChangeEnd!(_value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // 大きい円盤は中の文字も少し大きく
    final style = (widget.size >= 120 ? text.bodyMedium : text.labelSmall)!;
    final readOnly = widget.readOnly;
    final active = !readOnly && (widget.valueMs.abs() >= 1 || _fine);
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
        // 動かしていなければ色の点、動かしていれば量（+ は曲を先へ）
        child: Center(
          child: active
              ? Text(
                  [
                    if (_fine) '微調整',
                    if (widget.valueMs.abs() >= 1)
                      '${widget.valueMs > 0 ? '+' : '−'}${widget.valueMs.abs().round()}ms',
                  ].join('\n'),
                  textAlign: TextAlign.center,
                  style: style.copyWith(
                    color: Colors.white,
                    height: 1.2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                )
              : Container(
                  width: (widget.size * 0.12).clamp(8.0, 16.0),
                  height: (widget.size * 0.12).clamp(8.0, 16.0),
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                  ),
                ),
        ),
      ),
    );
    if (readOnly) {
      // 触れても何も起きない（鳴っている曲を動かさない）
      return AbsorbPointer(child: disc);
    }
    // 長押しは GestureDetector に足すとドラッグと取り合いになり、回し始めに 36px の
    // 遊びが出る。指を置いてからの時間と動きで自分で見る
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _onPointerUp(),
      onPointerCancel: (_) => _onPointerUp(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => _begin(d.localPosition, d.sourceTimeStamp),
        onPanUpdate: (d) => _move(d.localPosition, d.sourceTimeStamp),
        onPanEnd: (_) => _finish(allowGlide: true),
        onPanCancel: () => _finish(allowGlide: false),
        child: disc,
      ),
    );
  }

  Timer? _holdTimer;

  void _onPointerDown(PointerDownEvent e) {
    _downAt = e.localPosition;
    // 滑っている間に触れたら止める（回せばそこから続く）
    if (_glide.isActive) {
      _glide.stop();
      widget.onChangeEnd!(_value);
    }
    _holdTimer?.cancel();
    _holdTimer = Timer(JogWheel.holdForFine, () {
      if (!mounted) return;
      HapticFeedback.selectionClick();
      setState(() => _fine = true);
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    final down = _downAt;
    // 動かし始めたら長押しではない（微調整に入った後はそのまま）
    if (!_fine && down != null && (e.localPosition - down).distance > 8) {
      _holdTimer?.cancel();
    }
  }

  void _onPointerUp() {
    _holdTimer?.cancel();
    _downAt = null;
    if (_fine && _lastAngle == null) setState(() => _fine = false);
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
