import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/bpm_key_detector.dart';
import 'package:u2b_loop_app/core/audio/tempo_sections.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

const _sr = BpmKeyDetector.analysisSampleRate;

/// [bpm] のクリック音（短いノイズバースト）。[seed] で音色を変える
Int16List _click(double bpm, double seconds, {int seed = 0}) {
  final y = Int16List((_sr * seconds).round());
  final period = _sr * 60 / bpm;
  final rng = Random(seed);
  for (var k = 0;; k++) {
    final i = (k * period).round();
    if (i + 300 >= y.length) break;
    for (var j = 0; j < 300; j++) {
      y[i + j] = ((rng.nextDouble() * 2 - 1) * (1 - j / 300) * 20000).round();
    }
  }
  return y;
}

Int16List _concat(List<Int16List> parts) {
  final out = Int16List(parts.fold(0, (n, p) => n + p.length));
  var o = 0;
  for (final p in parts) {
    out.setAll(o, p);
    o += p.length;
  }
  return out;
}

List<TempoSection> _detect(Int16List pcm) =>
    TempoSectionDetector.detect(BpmKeyDetector.onsetEnvelope(pcm, _sr)!, startMs: 0);

void main() {
  test('120 → 150 BPM: 区切りは 2 つ、境目は 3 秒以内', () {
    final s = _detect(_concat([_click(120, 60), _click(150, 60, seed: 1)]));
    expect(s, hasLength(2));
    expect(s[0].startMs, 0);
    expect(s[0].bpm, closeTo(120, 1.5));
    expect(s[1].bpm, closeTo(150, 1.5));
    expect(s[1].startMs, closeTo(60000, 3000));
  });

  test('テンポが一定なら区切りは無い', () {
    expect(_detect(_click(128, 120)), isEmpty);
  });

  test('倍テンポ（100 → 200）は同じテンポとして区切らない', () {
    expect(_detect(_concat([_click(100, 60), _click(200, 60, seed: 1)])), isEmpty);
  });

  test('短すぎる区切り（8 秒）は混ぜる', () {
    expect(
        _detect(_concat([_click(120, 50), _click(150, 8, seed: 1), _click(120, 50, seed: 2)])),
        isEmpty);
  });

  test('解析: メインの BPM は一番長い区切りのテンポ、格子もそこで求める', () {
    final r = BpmKeyDetector.analyze(_concat([_click(120, 50), _click(150, 80, seed: 1)]), _sr);
    expect(r.sections, hasLength(2));
    expect(r.bpm, closeTo(150, 1.5));
    expect(r.beatGrid!.bpm, closeTo(150, 1.5));
    expect(r.sections[1].bpm, r.bpm, reason: '表示の範囲とメインの値が揃う');
  });

  test('保存の形は往復する', () {
    const s = [TempoSection(0, 120), TempoSection(61000, 150.5)];
    final back = TempoSection.unflatten(TempoSection.flatten(s));
    expect(back.map((x) => (x.startMs, x.bpm)), [(0, 120.0), (61000, 150.5)]);
  });

  test('表記: 一定なら「120 BPM」、変わるなら「150 BPM（100〜150）」', () {
    expect(LoopItem.formatBpm(120.4, const []), '120 BPM');
    expect(LoopItem.formatBpm(150, const [TempoSection(0, 100), TempoSection(60000, 150)]),
        '150 BPM（100〜150）');
    final item = LoopItem(id: 'a', title: 't', uri: 'u', sourceType: 'local', bpm: 150)
      ..tempoSectionData = TempoSection.flatten(const [TempoSection(0, 100), TempoSection(81000, 150)]);
    expect(item.bpmLabel, '150 BPM（100〜150）');
    expect(item.tempoSectionsLabel, '0:00 100 → 1:21 150');
  });
}
