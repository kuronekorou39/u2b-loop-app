import 'package:flutter/material.dart';

/// ローディングアニメーションの基底クラス。
/// 新しいアニメーションを追加するには、このクラスを継承して
/// [paint] と [shouldRepaint] を実装する。
abstract class LoadingAnimation extends CustomPainter {
  LoadingAnimation({required this.elapsed, required this.size});

  /// アニメーション開始からの経過時間
  final double elapsed;

  /// 描画領域のサイズ
  final Size size;
}

/// アニメーションの種類
enum LoadingAnimationType {
  wave,
  // 将来追加: mystify, starfield, pipes, ...
}

/// アニメーション種別から対応する [CustomPainter] を生成するファクトリ。
/// [colors] でアプリテーマの色を渡す。
typedef LoadingAnimationFactory = LoadingAnimation Function({
  required double elapsed,
  required Size size,
  required List<Color> colors,
});
