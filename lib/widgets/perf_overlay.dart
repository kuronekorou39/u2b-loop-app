import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 画面下部に表示するカスタムパフォーマンスオーバーレイ。
/// FPS・フレ�����描画時間をリアルタイム表示。
class PerfOverlay extends StatefulWidget {
  const PerfOverlay({super.key});

  @override
  State<PerfOverlay> createState() => _PerfOverlayState();
}

class _PerfOverlayState extends State<PerfOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _prev = Duration.zero;
  final _frameTimes = <double>[];
  static const _maxSamples = 60;

  double _fps = 0;
  double _frameMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    if (_prev != Duration.zero) {
      final dt = (elapsed - _prev).inMicroseconds / 1000.0;
      _frameTimes.add(dt);
      if (_frameTimes.length > _maxSamples) _frameTimes.removeAt(0);

      final avg =
          _frameTimes.reduce((a, b) => a + b) / _frameTimes.length;
      _fps = avg > 0 ? (1000.0 / avg) : 0;
      _frameMs = avg;

      // 10フ��ームごとにUI更新（オーバーレイ自体の負荷を抑える）
      if (_frameTimes.length % 10 == 0) {
        setState(() {});
      }
    }
    _prev = elapsed;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Color _fpsColor(double fps) {
    if (fps >= 55) return const Color(0xFF4ECCA3);
    if (fps >= 30) return const Color(0xFFFFD93D);
    return const Color(0xFFE94560);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottomPadding + 4,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _fpsColor(_fps),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_fps.toStringAsFixed(1)} FPS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _fpsColor(_fps),
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_frameMs.toStringAsFixed(1)} ms/f',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xCCFFFFFF),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
