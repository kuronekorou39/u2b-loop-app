import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 画面下部に表示するカスタムパフォーマンスオーバーレイ。
/// FPS・最悪フレーム時間・ジャンク数をリアルタイム表示。
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
  static const _jankThresholdMs = 18.0; // 60FPSの1フレーム=16.7ms、余裕を持って18ms

  double _fps = 0;
  double _worstMs = 0;
  int _jankCount = 0;
  int _updateCounter = 0;

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

      // 10フレームごとにUI更新
      _updateCounter++;
      if (_updateCounter >= 10) {
        _updateCounter = 0;
        final avg =
            _frameTimes.reduce((a, b) => a + b) / _frameTimes.length;
        _fps = avg > 0 ? (1000.0 / avg) : 0;
        _worstMs = _frameTimes.reduce((a, b) => a > b ? a : b);
        _jankCount =
            _frameTimes.where((t) => t > _jankThresholdMs).length;
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

  Color _jankColor(int count) {
    if (count == 0) return const Color(0xFF4ECCA3);
    if (count <= 3) return const Color(0xFFFFD93D);
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
                // FPS
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
                  '${_fps.toStringAsFixed(0)} FPS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _fpsColor(_fps),
                    fontFamily: 'monospace',
                  ),
                ),
                _separator(),
                // 最悪フレーム
                Text(
                  'worst ${_worstMs.toStringAsFixed(0)}ms',
                  style: TextStyle(
                    fontSize: 11,
                    color: _worstMs > _jankThresholdMs
                        ? const Color(0xFFFFD93D)
                        : const Color(0xCCFFFFFF),
                    fontFamily: 'monospace',
                  ),
                ),
                _separator(),
                // ジャンク数
                Text(
                  'jank $_jankCount/${_frameTimes.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: _jankColor(_jankCount),
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

  Widget _separator() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '|',
        style: TextStyle(fontSize: 11, color: Color(0x66FFFFFF)),
      ),
    );
  }
}
