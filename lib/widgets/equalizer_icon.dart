import 'dart:math';
import 'package:flutter/material.dart';

/// 3本バーが上下するイコライザーアニメーション（再生中インジケーター）
class EqualizerIcon extends StatefulWidget {
  final Color color;
  final double size;

  const EqualizerIcon({
    super.key,
    this.color = Colors.green,
    this.size = 18,
  });

  @override
  State<EqualizerIcon> createState() => _EqualizerIconState();
}

class _EqualizerIconState extends State<EqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _EqualizerPainter(
            t: t,
            color: widget.color,
          ),
        );
      },
    );
  }
}

class _EqualizerPainter extends CustomPainter {
  final double t;
  final Color color;

  _EqualizerPainter({required this.t, required this.color});

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
      // sin波で0.3〜1.0の範囲で振動
      final h = 0.3 + 0.7 * ((sin((t + phase) * 2 * pi) + 1) / 2);
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
  bool shouldRepaint(_EqualizerPainter old) => old.t != t;
}
