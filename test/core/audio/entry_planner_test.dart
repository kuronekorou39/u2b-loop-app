import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/energy_profile.dart';
import 'package:u2b_loop_app/core/audio/entry_planner.dart';

/// 次曲の入り口: 前曲が盛り上がって終わるなら静かなイントロを飛ばして同じくらい鳴る段落の頭、
/// 静かに終わるなら曲頭のまま
void main() {
  const step = EnergyProfile.curveStepMs; // 2 秒

  /// [secs] 秒ごとの dB の列を 2 秒刻みの流れにする（1 要素 = 2 秒）
  List<double> curve(List<double> perStep) => perStep;

  /// 3 分の曲: 0〜60 秒は静か（−18dB）、60 秒からサビ（−6dB）、
  /// 120〜150 秒で静か、150 秒から再びサビ
  final gradual = curve([
    for (var i = 0; i < 30; i++) -18.0,
    for (var i = 0; i < 30; i++) -6.0,
    for (var i = 0; i < 15; i++) -18.0,
    for (var i = 0; i < 15; i++) -6.0,
  ]);

  // 125 BPM: 1 拍 480ms、1 フレーズ（32 拍）= 15,360ms。拍の頭は 0 から
  const grid = BeatGrid(bpm: 125, offsetMs: 0, confidence: 0.9);

  group('段落表', () {
    test('格子があればフレーズの頭ごと、曲の前半まで。先頭は曲頭', () {
      final s = EntryPlanner.sections(gradual, stepMs: step, grid: grid);
      expect(s.first.ms, 0);
      expect(s.first.db, closeTo(-18, 0.01));
      // 2 つ目以降はフレーズの頭（15,360ms ごと）
      expect(s[1].ms, closeTo(15360, 0.01));
      expect(s[2].ms, closeTo(30720, 0.01));
      // 90 秒（曲の半分）より後は無い
      expect(s.last.ms, lessThan(90000));
      expect(s.every((e) => e.ms < 90000), isTrue);
      // 61,440ms から始まる段落はサビの中（−6dB）
      final chorus = s.firstWhere((e) => e.ms >= 60000);
      expect(chorus.db, closeTo(-6, 0.01));
    });

    test('格子が無ければ 16 秒ごと', () {
      final s = EntryPlanner.sections(gradual, stepMs: step);
      expect(s[1].ms, 16000);
      expect(s[2].ms, 32000);
    });

    test('無音の分だけ曲頭が後ろにずれ、曲頭に近すぎる候補は入れない', () {
      final s = EntryPlanner.sections(gradual,
          stepMs: step, grid: grid, leadingSilenceMs: 14000);
      expect(s.first.ms, 14000);
      // 次のフレーズの頭 15,360 は曲頭から 2 秒未満なので飛ばし、30,720 から
      expect(s[1].ms, closeTo(30720, 0.01));
    });

    test('出口は切断点の手前 1 段落の平均', () {
      // 曲末がサビのまま終わる（−6dB）
      final exit = EntryPlanner.exitDb(gradual, 180000, stepMs: step, grid: grid);
      expect(exit, closeTo(-6, 0.01));
      // 120〜150 秒の静かな所で切るなら −18
      final quiet = EntryPlanner.exitDb(gradual, 150000, stepMs: step, grid: grid);
      expect(quiet, closeTo(-18, 0.01));
    });
  });

  group('入り口', () {
    final sections = EntryPlanner.sections(gradual, stepMs: step, grid: grid);

    test('前曲が盛り上がって終わる → 静かなイントロを飛ばし、同じくらい鳴る最初の段落の頭', () {
      final entry = EntryPlanner.entryMs(exitDb: -6, sections: sections);
      // 60 秒から鳴り出す。その直後のフレーズの頭（61,440ms）
      expect(entry, closeTo(61440, 0.01));
    });

    test('前曲が静かに終わる → 曲頭のまま（null）', () {
      expect(EntryPlanner.entryMs(exitDb: -18, sections: sections), isNull);
      // 出口が曲頭より少し大きいだけ（3dB 未満）でも曲頭
      expect(EntryPlanner.entryMs(exitDb: -16, sections: sections), isNull);
    });

    test('出口ほど鳴る段落が無ければ、曲頭より明らかに大きい一番鳴る段落', () {
      // 全体が −18 で、40 秒だけ −12 の曲
      final mild = curve([
        for (var i = 0; i < 20; i++) -18.0,
        for (var i = 0; i < 10; i++) -12.0,
        for (var i = 0; i < 60; i++) -18.0,
      ]);
      final s = EntryPlanner.sections(mild, stepMs: step);
      final entry = EntryPlanner.entryMs(exitDb: -3, sections: s);
      expect(entry, 48000);
    });

    test('どの段落も曲頭と同じくらいなら曲頭（飛ばす意味が無い）', () {
      final flat = curve(List.filled(90, -18.0));
      final s = EntryPlanner.sections(flat, stepMs: step);
      expect(EntryPlanner.entryMs(exitDb: -3, sections: s), isNull);
    });
  });
}
