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

  group('outroIsQuiet（検出したアウトロの後で音量が下がっているか）', () {
    test('全体の音量が下がっていればアウトロ', () {
      expect(
          ExitPlanner.outroIsQuiet(curve(180, 240),
              stepMs: step, mixOutMs: 180000, endMs: 240000),
          isTrue);
    });

    test('最後まで同じ音量で鳴り、曲の後が無音なだけならアウトロではない', () {
      final c = [
        for (var i = 0; i < 110; i++) -9.0,
        for (var i = 0; i < 10; i++) -60.0,
      ];
      expect(
          ExitPlanner.outroIsQuiet(c,
              stepMs: step, mixOutMs: 180000, endMs: 240000),
          isFalse);
    });

    test('ベースが抜けただけで音量が変わらなければアウトロではない', () {
      expect(
          ExitPlanner.outroIsQuiet(curve(180, 240, loud: -6, quiet: -7),
              stepMs: step, mixOutMs: 180000, endMs: 240000),
          isFalse);
    });
  });

  test('曲の後の無音まではフェードの長さに数えない（最後の音の余韻）', () {
    final c = [
      for (var i = 0; i < 118; i++) -6.0,
      -14.0,
      -24.0,
      for (var i = 0; i < 10; i++) -60.0,
    ];
    expect(ExitPlanner.fadeStartMs(c, stepMs: step), isNull);
  });

  group('fadeStartMs（曲の終わりのフェードアウトの始まり）', () {
    /// [bodySec] 秒まで −5dB、そこから [fadeSec] 秒かけて −55dB へ
    List<double> fading(int bodySec, int fadeSec) => [
          for (var i = 0; i < bodySec ~/ 2; i++) -5.0,
          for (var i = 1; i <= fadeSec ~/ 2; i++) -5.0 - 50.0 * i / (fadeSec ~/ 2),
        ];

    test('本体の音量から 3dB 下がる手前が始まり', () {
      // 20 秒のフェード: 2 秒ごとに 5dB 下がるので、最初の点で −10dB（3dB を超える）
      expect(ExitPlanner.fadeStartMs(fading(200, 20), stepMs: step), 200000);
    });

    test('最後まで鳴っている曲は null', () {
      expect(ExitPlanner.fadeStartMs(curve(240, 240), stepMs: step), isNull);
    });

    test('最後の音の余韻（短い下がり）は null', () {
      expect(ExitPlanner.fadeStartMs(fading(234, 4), stepMs: step), isNull);
    });

    test('静かな終盤が長い曲（曲の一部）は null', () {
      expect(ExitPlanner.fadeStartMs(fading(160, 80), stepMs: step), isNull);
    });

    test('下がりきらない終わり方は null', () {
      expect(
          ExitPlanner.fadeStartMs(curve(200, 240, loud: -5, quiet: -12), stepMs: step),
          isNull);
    });
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
