import 'package:flutter/material.dart';

/// 組が次へ進むときの切り替え。一瞬で入れ替えると違和感があるので、出る側は進む向き
/// （[direction]）へ抜けながら消え、入る側はその反対側から同じ向きに入ってくる。
/// 重ね表示の帯は上へ（次曲の段が前曲の段に上がる）、デッキの板は左へ
/// （次曲の円盤が前曲の位置へ）。
///
/// [child] の key が変わったときだけ動く（同じ key なら差し替えるだけ）。
/// 出る側と入る側は同じ大きさの前提（動いている間も場所を取らない。はみ出す分は切る）
class AdvanceSwitcher extends StatelessWidget {
  const AdvanceSwitcher({
    super.key,
    required this.child,
    this.direction = AxisDirection.up,
    this.fraction = defaultFraction,
    this.duration = defaultDuration,
  });

  final Widget child;

  /// 進む向き（出る側が抜けていく向き）
  final AxisDirection direction;

  /// 動く距離（自分の大きさに対する割合）
  final double fraction;

  final Duration duration;

  static const defaultFraction = 0.35;
  static const defaultDuration = Duration(milliseconds: 360);

  @override
  Widget build(BuildContext context) => ClipRect(
        child: AnimatedSwitcher(
          duration: duration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => _Slide(
            direction: direction,
            fraction: fraction,
            animation: animation,
            child: child,
          ),
          child: child,
        ),
      );
}

/// 入る側（0→1）は反対側から、出る側（1→0）は進む向きへ。
/// [AnimatedSwitcher] は両方に同じ builder を使うので、向きはアニメーションの状態で見分ける
class _Slide extends AnimatedWidget {
  const _Slide({
    required this.direction,
    required this.fraction,
    required Animation<double> animation,
    required this.child,
  }) : super(listenable: animation);

  final AxisDirection direction;
  final double fraction;
  final Widget child;

  Animation<double> get animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final t = animation.value.clamp(0.0, 1.0);
    final leaving = animation.status == AnimationStatus.reverse;
    final away = (1 - t) * fraction;
    final forward = switch (direction) {
      AxisDirection.up => const Offset(0, -1),
      AxisDirection.down => const Offset(0, 1),
      AxisDirection.left => const Offset(-1, 0),
      AxisDirection.right => const Offset(1, 0),
    };
    return Opacity(
      opacity: t,
      child: FractionalTranslation(
        translation: forward * (leaving ? away : -away),
        child: child,
      ),
    );
  }
}
