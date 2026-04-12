import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/theme/app_theme.dart';
import 'loading_animation.dart';
import 'mystify_animation.dart';
import 'particles_animation.dart';
import 'starfield_animation.dart';
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
  LoadingAnimationType.mystify: ({
    required double elapsed,
    required Size size,
    required List<Color> colors,
  }) =>
      MystifyAnimation(elapsed: elapsed, size: size, colors: colors),
  LoadingAnimationType.starfield: ({
    required double elapsed,
    required Size size,
    required List<Color> colors,
  }) =>
      StarfieldAnimation(elapsed: elapsed, size: size, colors: colors),
  LoadingAnimationType.particles: ({
    required double elapsed,
    required Size size,
    required List<Color> colors,
  }) =>
      ParticlesAnimation(elapsed: elapsed, size: size, colors: colors),
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
  final _elapsed = ValueNotifier<double>(0);
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
      _elapsed.value = duration.inMilliseconds / 1000.0;
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final factory = _registry[_activeType]!;
        return CustomPaint(
          painter: _RepaintablePainter(
            repaint: _elapsed,
            factory: factory,
            size: size,
            colors: _colors,
            elapsed: _elapsed,
          ),
          size: size,
        );
      },
    );
  }
}

/// [ValueNotifier] の変化で repaint するだけの軽量ラッパー。
/// setState を使わずに描画を更新���る。
class _RepaintablePainter extends CustomPainter {
  _RepaintablePainter({
    required Listenable repaint,
    required this.factory,
    required this.size,
    required this.colors,
    required this.elapsed,
  }) : super(repaint: repaint);

  final LoadingAnimationFactory factory;
  final Size size;
  final List<Color> colors;
  final ValueNotifier<double> elapsed;

  @override
  void paint(Canvas canvas, Size size) {
    final painter = factory(
      elapsed: elapsed.value,
      size: size,
      colors: colors,
    );
    painter.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _RepaintablePainter oldDelegate) => false;
}
