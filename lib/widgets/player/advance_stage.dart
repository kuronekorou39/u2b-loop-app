import 'package:flutter/material.dart';

/// 組が次へ進むときの 5 拍子。進み具合はそれぞれ 0〜1（順に進む。動いていなければ全部 1）:
/// 1. [hide] 2 段をまたぐ線（音量曲線・切替点・効果音の印）が消える
/// 2. [leave] 前曲が左へ抜ける
/// 3. [rise] 次曲が前曲の位置へ移る（帯なら上の段へ、板なら左の盤へ）
/// 4. [enter] 新しい次曲が右から入ってくる
/// 5. [show] またぐ線が新しい組の形で現れる
typedef AdvancePhases = ({
  double hide,
  double leave,
  double rise,
  double enter,
  double show,
});

/// 5 拍子の演出の土台（ユーザー案 2026-10-25: 「上の波形を左へシューッと消し、
/// 下の波形を上へ、右から次曲の波形がシューッと入る。音量の線は先に消して、
/// 次曲の波形が出てから出す」）。
/// [stageKey] が変わったら前の値（[T]）を覚えて動かし、[builder] に今の値・前の値・
/// 進み具合を渡す。並べ方は使う側（帯 = [MixLanesAdvance]、板 = [MixDeck]）が決める。
/// 動いていないときは previous が null で、進み具合はすべて 1
class AdvanceStage<T> extends StatefulWidget {
  const AdvanceStage({
    super.key,
    required this.stageKey,
    required this.value,
    required this.builder,
    this.duration = defaultDuration,
  });

  /// どの組か。変わったら動く
  final Key stageKey;

  final T value;

  final Widget Function(
    BuildContext context,
    T current,
    T? previous,
    AdvancePhases phases,
  ) builder;

  final Duration duration;

  static const defaultDuration = Duration(milliseconds: 1200);

  /// 動いていないときの進み具合
  static const AdvancePhases done =
      (hide: 1, leave: 1, rise: 1, enter: 1, show: 1);

  /// 5 拍子の割り当て（全体の 0〜1 に対する区間。1.2 秒なら
  /// 線が消える 0.15 秒 → 去る 0.25 → 上がる 0.3 → 来る 0.3 → 線が出る 0.2）。
  /// 抜けるのは加速、入るのは減速
  static const hideInterval = Interval(0, 0.125, curve: Curves.easeIn);
  static const leaveInterval =
      Interval(0.125, 1 / 3, curve: Curves.easeInCubic);
  static const riseInterval =
      Interval(1 / 3, 0.583, curve: Curves.easeInOutCubic);
  static const enterInterval =
      Interval(0.583, 0.833, curve: Curves.easeOutCubic);
  static const showInterval = Interval(0.833, 1, curve: Curves.easeOut);

  static AdvancePhases phasesAt(double t) => (
        hide: hideInterval.transform(t),
        leave: leaveInterval.transform(t),
        rise: riseInterval.transform(t),
        enter: enterInterval.transform(t),
        show: showInterval.transform(t),
      );

  /// またぐ線の濃さ: 前の組は消えていく（[AdvancePhases.hide]）、
  /// 新しい組は最後に現れる（[AdvancePhases.show]）
  static double hidingOpacity(AdvancePhases p) => 1 - p.hide;
  static double showingOpacity(AdvancePhases p) => p.show;

  @override
  State<AdvanceStage<T>> createState() => _AdvanceStageState<T>();
}

class _AdvanceStageState<T> extends State<AdvanceStage<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..addStatusListener(_onStatus);

  /// 動いている間だけ、前の値
  T? _previous;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous != null) {
      setState(() => _previous = null);
    }
  }

  @override
  void didUpdateWidget(covariant AdvanceStage<T> old) {
    super.didUpdateWidget(old);
    if (old.stageKey != widget.stageKey) {
      _previous = old.value;
      _controller
        ..duration = widget.duration
        ..forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final previous = _previous;
    if (previous == null) {
      return widget.builder(context, widget.value, null, AdvanceStage.done);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => widget.builder(
        context,
        widget.value,
        previous,
        AdvanceStage.phasesAt(_controller.value),
      ),
    );
  }
}
