import 'package:flutter/material.dart';

/// ローディングアニメーションの基底クラス。
/// 新しいアニメーションを追加するには、このクラスを継承して
/// [paint] と [shouldRepaint] を実装する。
abstract class LoadingAnimation extends CustomPainter {
  LoadingAnimation({required this.elapsed});

  /// アニメーション開始からの経過時間
  final double elapsed;
}

/// アニメーションの種類
enum LoadingAnimationType {
  wave,
  mystify,
  starfield,
  particles,
  off,
}

/// アニメーション種別から対応する [CustomPainter] を生成するファクトリ。
/// [colors] でアプリテーマの色を渡す。
typedef LoadingAnimationFactory = LoadingAnimation Function({
  required double elapsed,
  required List<Color> colors,
});
