import 'dart:math';
import 'package:flutter/material.dart';

/// 3本バーが上下するイコライザーアニメーション（再生中インジケーター）。
/// 一時停止中（[playing] が false）は音が出ていないので、バーを一番低い所まで下げて止める
class EqualizerIcon extends StatefulWidget {
  final Color color;
  final double size;
  final bool playing;

  const EqualizerIcon({
    super.key,
    this.color = Colors.green,
    this.size = 18,
    this.playing = true,
  });

  @override
  State<EqualizerIcon> createState() => _EqualizerIconState();
}

class _EqualizerIconState extends State<EqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 揺れの大きさ（1 = 再生中、0 = 止まって一番低い）。止めるときはここを 0 へ下ろす
  late final AnimationController _level;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _level = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.playing ? 1 : 0,
    )..addStatusListener((status) {
        // 下げ切ったら揺れも止める（止まっている間は描き直さない）
        if (status == AnimationStatus.dismissed) _controller.stop();
      });
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(EqualizerIcon old) {
    super.didUpdateWidget(old);
    if (widget.playing == old.playing) return;
    if (widget.playing) {
      if (!_controller.isAnimating) _controller.repeat();
      _level.forward();
    } else {
      _level.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _level]),
      builder: (context, _) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _EqualizerPainter(
            t: _controller.value,
            level: _level.value,
            color: widget.color,
          ),
        );
      },
    );
  }
}

class _EqualizerPainter extends CustomPainter {
  final double t;
  final double level;
  final Color color;

  _EqualizerPainter({required this.t, required this.level, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const barCount = 3;
    final barWidth = size.width / (barCount * 2 - 1);
    final maxHeight = size.height;

    // 各バーに異なる位相を与える
    const phases = [0.0, 0.4, 0.8];
    for (var i = 0; i < barCount; i++) {
      final phase = phases[i];
      // sin波で0.3〜1.0の範囲で振動。[level] が 0 に近いほど 0.3（一番低い）に寄る
      final h = 0.3 + 0.7 * level * ((sin((t + phase) * 2 * pi) + 1) / 2);
      final barHeight = maxHeight * h;
      final x = i * barWidth * 2;
      final y = maxHeight - barHeight;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, barHeight),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EqualizerPainter old) =>
      old.t != t || old.level != level || old.color != color;
}
