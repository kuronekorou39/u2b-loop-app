import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/wave_bands.dart';

const _sr = 11025;

Int16List _sine(double hz, double seconds, {double amp = 0.5}) => Int16List.fromList([
      for (var i = 0; i < (_sr * seconds).round(); i++)
        (sin(2 * pi * hz * i / _sr) * amp * 32767).round(),
    ]);

Int16List _concat(List<Int16List> parts) {
  final out = Int16List(parts.fold(0, (n, p) => n + p.length));
  var o = 0;
  for (final p in parts) {
    out.setAll(o, p);
    o += p.length;
  }
  return out;
}

void main() {
  test('低い音は低音、真ん中の音は中音、高い音は高音に出る', () {
    // 2 秒ずつ: 80Hz → 600Hz → 4000Hz
    final b = WaveBands.fromPcm(
        _concat([_sine(80, 2), _sine(600, 2), _sine(4000, 2)]), _sr)!;
    final low = b.maxIn(500, 1500)!, mid = b.maxIn(2500, 3500)!, high = b.maxIn(4500, 5500)!;
    expect(low.low, greaterThan(0.8));
    expect(low.mid, lessThan(0.2));
    expect(mid.mid, greaterThan(0.8));
    expect(mid.low, lessThan(0.2));
    expect(high.high, greaterThan(0.8));
    expect(high.mid, lessThan(0.2));
  });

  test('50ms ごと。求めた範囲の外は null', () {
    final b = WaveBands.fromPcm(_sine(440, 3), _sr)!;
    expect(b.stepMs, 50);
    expect(b.durationMs, closeTo(3000, 120));
    expect(b.maxIn(10000, 10100), isNull);
  });

  test('保存の形は往復する', () {
    final b = WaveBands.fromPcm(_concat([_sine(80, 1), _sine(4000, 1)]), _sr)!;
    final back = WaveBands.decode(b.encode())!;
    expect(back.stepMs, b.stepMs);
    expect(back.low, b.low);
    expect(back.mid, b.mid);
    expect(back.high, b.high);
    expect(WaveBands.decode(Uint8List(3)), isNull);
  });
}
