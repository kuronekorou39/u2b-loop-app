import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/loop/playback_stall_watch.dart';

void main() {
  final t0 = DateTime(2026);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
  const pos = Duration(milliseconds: 541);

  test('位置が止まったままなら一定時間後に知らせ、続けて知らせない', () {
    final w = PlaybackStallWatch();
    expect(w.shouldKick(position: pos, active: true, now: at(0)), isFalse);
    expect(w.shouldKick(position: pos, active: true, now: at(1400)), isFalse);
    expect(w.shouldKick(position: pos, active: true, now: at(1500)), isTrue);
    expect(w.shouldKick(position: pos, active: true, now: at(1600)), isFalse);
    expect(w.shouldKick(position: pos, active: true, now: at(3000)), isTrue);
  });

  test('位置が進んでいれば知らせない', () {
    final w = PlaybackStallWatch();
    for (var ms = 0; ms <= 4000; ms += 100) {
      final moved = Duration(milliseconds: ms);
      expect(w.shouldKick(position: moved, active: true, now: at(ms)), isFalse);
    }
  });

  test('一時停止や読み込み待ちの間は数えない', () {
    final w = PlaybackStallWatch();
    w.shouldKick(position: pos, active: true, now: at(0));
    expect(w.shouldKick(position: pos, active: false, now: at(5000)), isFalse);
    expect(w.shouldKick(position: pos, active: true, now: at(6000)), isFalse);
    expect(w.shouldKick(position: pos, active: true, now: at(6500)), isTrue);
  });
}
