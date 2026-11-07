import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/tempo_sections.dart';
import 'package:u2b_loop_app/core/audio/track_compatibility.dart';
import 'package:u2b_loop_app/core/audio/transition_planner.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

/// 100 BPM（0〜60 秒）→ 150 BPM（60 秒〜、一番長い区切り）と変わる曲
LoopItem _changing({BeatGrid? head = const BeatGrid(bpm: 100, offsetMs: 40, confidence: 0.7)}) =>
    LoopItem(id: 'c', title: 'c', uri: 'c', sourceType: 'local')
      ..durationMs = 200000
      ..bpm = 150.5
      ..beatBpm = 150.5
      ..beatOffsetMs = 30
      ..beatConfidence = 0.8
      ..mixInMs = 90000
      ..tempoSectionData = TempoSection.flatten(
          const [TempoSection(0, 100), TempoSection(60000, 150)])
      ..sectionGridData = LoopItem.flattenGrids([
        head,
        const BeatGrid(bpm: 150, offsetMs: 0, confidence: 0.7),
      ]);

LoopItem _steady(double bpm, {String id = 's'}) =>
    LoopItem(id: id, title: id, uri: id, sourceType: 'local')
      ..bpm = bpm
      ..beatBpm = bpm
      ..beatOffsetMs = 0
      ..beatConfidence = 0.8;

void main() {
  group('位置ごとの格子とテンポ', () {
    test('一番長い区切りは曲の格子（手で直した値）、ほかはその区切りの格子', () {
      final item = _changing();
      expect(item.beatGridAt(80000)!.bpm, 150.5);
      expect(item.beatGridAt(10000)!.bpm, 100);
      expect(item.beatGridAt(10000)!.offsetMs, 40);
      expect(item.beatGridAt(null)!.bpm, 150.5);
      expect(item.bpmAt(10000), 100);
      expect(item.bpmAt(80000), 150.5);
    });

    test('ドロップを小節の基準にするのは一番長い区切りだけ', () {
      final item = _changing();
      expect(item.barAnchorAt(80000), 90000);
      expect(item.barAnchorAt(10000), isNull);
      expect(item.beatLinesAt(10000)!.anchorMs, isNull);
      expect(item.beatLinesAt(80000)!.anchorMs, 90000);
    });

    test('区切りの格子が取れていなければ格子なし・テンポは区切りの値', () {
      final item = _changing(head: null);
      expect(item.beatGridAt(10000), isNull);
      expect(item.bpmAt(10000), 100);
      expect(item.beatLinesAt(10000), isNull);
    });

    test('テンポが一定の曲はどこでも曲の格子', () {
      final item = _steady(128);
      expect(item.tempoSectionIndexAt(10000), isNull);
      expect(item.beatGridAt(10000)!.bpm, 128);
      expect(item.bpmAt(10000), 128);
    });

    test('保存はその位置の区切りへ（ほかの区切りと当てはまりは変えない）', () {
      final item = _changing();
      item.setBeatGridAt(
          10000, const BeatGrid(bpm: 101, offsetMs: 55, confidence: 0.1));
      expect(item.beatGridAt(10000)!.bpm, 101);
      expect(item.beatGridAt(10000)!.offsetMs, 55);
      expect(item.beatGridAt(10000)!.confidence, 0.7);
      expect(item.beatBpm, 150.5);
      expect(item.beatOffsetMs, 30);

      item.setBeatGridAt(
          80000, const BeatGrid(bpm: 151, offsetMs: 12, confidence: 0.1));
      expect(item.beatBpm, 151);
      expect(item.beatOffsetMs, 12);
      expect(item.beatConfidence, 0.8);
      expect(item.beatGridAt(10000)!.bpm, 101);
    });

    test('表示のテンポを直すのはその区切り（一番長い区切りなら曲の BPM も）', () {
      final item = _changing();
      item.scaleBpmAt(10000, 1.02);
      expect(item.tempoSections[0].bpm, 102);
      expect(item.bpm, 150.5);
      item.scaleBpmAt(80000, 0.5);
      expect(item.tempoSections[1].bpm, 75);
      expect(item.bpm, 75.3);
    });

    test('始まりと終わりのテンポ', () {
      final item = _changing();
      expect(item.startBpm, 100);
      expect(item.endBpm, 150);
      expect(_steady(128).startBpm, 128);
    });
  });

  test('相性は前の曲の終わりのテンポと次の曲の始まりのテンポで比べる', () {
    final out = _steady(100, id: 'o');
    // 表示の BPM は 150 でも始まりは 100 なので、100 の曲の次にぴったり
    expect(TrackCompatibility.score(out, _changing()),
        greaterThan(TrackCompatibility.score(out, _steady(150.5, id: 'n'))));
  });

  test('おまかせは重なる位置のテンポで決める', () {
    final out = _steady(100, id: 'o');
    // 曲全体の値（150.5）だとテンポ差が大きすぎて短く切り替える
    final whole = TransitionPlanner.plan(out, _changing());
    // 入り口が曲頭の区切り（100 BPM）ならテンポが合う
    final atHead = TransitionPlanner.plan(out, _changing(), inAtMs: 10000);
    expect(whole.tempoMatch, isFalse);
    expect(atHead.tempoMatch, isTrue);
    expect(atHead.beats, greaterThan(whole.beats));
  });
}
