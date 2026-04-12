import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/theme/app_theme.dart';
import 'loading_animation.dart';
import 'wave_animation.dart';

/// ローディングアニメーションの登録テーブル。
/// 新しいアニメーションを追加するときはここにエントリを足すだけ。
final Map<LoadingAnimationType, LoadingAnimationFactory> _registry = {
  LoadingAnimationType.wave: ({
    required double elapsed,
    required Size size,
    required List<Color> colors,
  }) =>
      WaveAnimation(elapsed: elapsed, size: size, colors: colors),
};

/// ローディング中に背景アニメーションを描画するウィジェット。
///
/// [type] を指定すればそのアニメーションを表示。
/// null なら登録済みの中からランダムに選ばれる。
class LoadingAnimationView extends StatefulWidget {
  const LoadingAnimationView({super.key, this.type});

  final LoadingAnimationType? type;

  @override
  State<LoadingAnimationView> createState() => _LoadingAnimationViewState();
}

class _LoadingAnimationViewState extends State<LoadingAnimationView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _elapsed = 0;
  late final LoadingAnimationType _activeType;

  static const _colors = [
    AppTheme.accentGreen,
    AppTheme.pointAColor,
    AppTheme.accentRed,
    Color(0xFF4FC3F7),
  ];

  @override
  void initState() {
    super.initState();
    _activeType = widget.type ??
        LoadingAnimationType
            .values[Random().nextInt(LoadingAnimationType.values.length)];
    _ticker = createTicker((duration) {
      setState(() => _elapsed = duration.inMilliseconds / 1000.0);
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final factory = _registry[_activeType]!;
        return CustomPaint(
          painter: factory(
            elapsed: _elapsed,
            size: size,
            colors: _colors,
          ),
          size: size,
        );
      },
    );
  }
}
