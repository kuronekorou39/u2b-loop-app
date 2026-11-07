import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/energy_profile.dart';
import 'package:u2b_loop_app/core/audio/exit_planner.dart';

/// 前の曲の出口: 最後の盛り上がりの後が静かで長いアウトロなら、盛り上がりの終わりで切る
void main() {
  const step = EnergyProfile.curveStepMs; // 2 秒

  /// [loudSec] 秒まで [loud] dB、そこから [totalSec] 秒まで [quiet] dB の流れ
  List<double> curve(int loudSec, int totalSec,
          {double loud = -6, double quiet = -18}) =>
      [
        for (var i = 0; i < loudSec ~/ 2; i++) loud,
        for (var i = 0; i < (totalSec - loudSec) ~/ 2; i++) quiet,
      ];

  test('静かなアウトロ（192〜240 秒）の前、盛り上がりの終わりで切る（格子が無ければ 16 秒ごと）', () {
    expect(
        ExitPlanner.exitMs(curve(192, 240), stepMs: step, cutMs: 240000), 192000);
  });

  test('格子があればフレーズの頭で', () {
    // 125 BPM: 1 フレーズ（32 拍）= 15,360ms。12 フレーズ目の頭 = 184,320ms
    const grid = BeatGrid(bpm: 125, offsetMs: 0, confidence: 0.9);
    expect(
        ExitPlanner.exitMs(curve(184, 240),
            stepMs: step, cutMs: 240000, grid: grid),
        closeTo(184320, 0.01));
  });

  test('最後まで鳴っている曲は今までどおり（null）', () {
    expect(ExitPlanner.exitMs(curve(240, 240), stepMs: step, cutMs: 240000),
        isNull);
  });

  test('アウトロがそれほど静かでなければ切らない', () {
    expect(
        ExitPlanner.exitMs(curve(192, 240, quiet: -9),
            stepMs: step, cutMs: 240000),
        isNull);
  });

  test('曲の前半から静かになる曲は切らない（曲の大半を捨てない）', () {
    expect(
        ExitPlanner.exitMs(curve(80, 240), stepMs: step, cutMs: 240000), isNull);
  });

  test('今の切断点（アウトロ点）より後ろの静けさは見ない', () {
    // 静かになるのは 224 秒からだが、切断点が 224 秒なら切り落とす残りが無い
    expect(
        ExitPlanner.exitMs(curve(224, 240), stepMs: step, cutMs: 224000),
        isNull);
  });

  test('格子の BPM が壊れていても止まらない', () {
    const broken = BeatGrid(bpm: 0, offsetMs: 0, confidence: 0.9);
    expect(
        ExitPlanner.exitMs(curve(192, 240),
            stepMs: step, cutMs: 240000, grid: broken),
        anyOf(isNull, isA<double>()));
  });
}
