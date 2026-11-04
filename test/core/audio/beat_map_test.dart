import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/beat_map.dart';
import 'package:u2b_loop_app/core/audio/key_sections.dart';
import 'package:u2b_loop_app/core/audio/tempo_sections.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

LoopItem _item() => LoopItem(id: 'a', title: 't', uri: 'u', sourceType: 'local');

void main() {
  test('テンポが一定なら曲全体を 1 つの格子で。信用できない格子は線を引かない', () {
    final item = _item()
      ..beatBpm = 120
      ..beatOffsetMs = 100
      ..beatConfidence = 0.8;
    final segs = BeatMap.segmentsOf(item);
    expect(segs, hasLength(1));
    expect(segs.single.grid.bpm, 120);
    item.beatConfidence = 0.1;
    expect(BeatMap.segmentsOf(item), isEmpty);
  });

  test('テンポが変わる曲は区切りごと。一番長い区切りは曲の格子（手で直した値）を使う', () {
    final item = _item()
      ..durationMs = 200000
      ..beatBpm = 150.5
      ..beatOffsetMs = 30
      ..beatConfidence = 0.8
      ..tempoSectionData = TempoSection.flatten(
          const [TempoSection(0, 100), TempoSection(60000, 150)])
      ..sectionGridData = LoopItem.flattenGrids(const [
        BeatGrid(bpm: 100, offsetMs: 0, confidence: 0.7),
        BeatGrid(bpm: 150, offsetMs: 0, confidence: 0.7),
      ]);
    expect(item.mainTempoSectionIndex, 1);
    final segs = BeatMap.segmentsOf(item);
    expect(segs.map((s) => (s.fromMs, s.toMs, s.grid.bpm)),
        [(0.0, 60000.0, 100.0), (60000.0, double.infinity, 150.5)]);
  });

  test('変わり目: テンポとキー（最初の区切りの頭は出さない）', () {
    final item = _item()
      ..tempoSectionData = TempoSection.flatten(
          const [TempoSection(0, 100), TempoSection(60000, 150)])
      ..keySectionData = LoopItem.flattenKeySections(
          const [KeySection(0, 'A#min'), KeySection(156000, 'Bmin')]);
    final m = BeatMap.markersOf(item);
    expect(m.map((x) => (x.ms, x.label, x.isKey)),
        [(60000.0, '150 BPM', false), (156000.0, 'Bm', true)]);
  });

  test('保存の形（区切りごとの格子）は往復する。無い格子は null', () {
    final flat = LoopItem.flattenGrids(const [
      BeatGrid(bpm: 100, offsetMs: 12, confidence: 0.5, downbeatMs: 2000, downbeatConfidence: 0.9),
      null,
    ]);
    final back = (_item()..sectionGridData = flat).sectionGrids;
    expect(back[0]!.downbeatMs, 2000);
    expect(back[0]!.offsetMs, 12);
    expect(back[1], isNull);
  });
}
