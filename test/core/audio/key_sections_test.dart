import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/bpm_key_detector.dart';
import 'package:u2b_loop_app/core/audio/cq_chroma.dart';
import 'package:u2b_loop_app/core/audio/key_sections.dart';
import 'package:u2b_loop_app/core/audio/track_compatibility.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

const _sr = BpmKeyDetector.analysisSampleRate;

/// [tonic] 長調の I-IV-V-I を 2 秒ずつ繰り返す（[seconds] 秒）
Int16List _major(int tonic, int seconds) {
  const degrees = [
    [0, 4, 7],
    [5, 9, 12],
    [7, 11, 14],
    [0, 4, 7],
  ];
  final y = Int16List(_sr * seconds);
  final seg = _sr * 2;
  for (var i = 0; i < y.length; i++) {
    final chord = degrees[(i ~/ seg) % 4];
    final t = i / _sr;
    var v = 0.0;
    for (final d in chord) {
      final f = 261.63 * pow(2, (tonic + d) / 12);
      v += sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t);
    }
    // ベース（主音の 2 オクターブ下）
    v += 0.8 * sin(2 * pi * 65.41 * pow(2, ((tonic + chord[0]) % 12) / 12) * t);
    y[i] = (v / 6 * 12000).round();
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

List<KeySection> _detect(Int16List pcm) =>
    KeySectionDetector.detect(CqChroma.frames(pcm, _sr), _sr, startMs: 0);

void main() {
  test('CQT のキー: 長調の進行を当て、半音ずらすとキーもずれる', () {
    for (final tonic in [0, 2, 7, 10]) {
      expect(BpmKeyDetector.detectKey(_major(tonic, 20), _sr).first.key,
          ['Cmaj', 'C#maj', 'Dmaj', 'D#maj', 'Emaj', 'Fmaj', 'F#maj', 'Gmaj', 'G#maj', 'Amaj', 'A#maj', 'Bmaj'][tonic]);
    }
  });

  test('C → D（全音上げ）の転調: 区切り 2 つ、境目は 5 秒以内', () {
    final s = _detect(_concat([_major(0, 90), _major(2, 90)]));
    expect(s.map((x) => x.key), ['Cmaj', 'Dmaj']);
    expect(s[1].startMs, closeTo(90000, 5000));
  });

  test('キーが一定なら区切りは無い', () {
    expect(_detect(_major(5, 150)), isEmpty);
  });

  test('5 度隣（C → G）への移りは転調にしない', () {
    expect(_detect(_concat([_major(0, 90), _major(7, 90)])), isEmpty);
  });

  test('表記と、DJ の相性は前の曲の終わりのキーと次の曲の始まりのキーで比べる', () {
    final a = LoopItem(id: 'a', title: 'a', uri: 'u', sourceType: 'local', musicalKey: 'A#min')
      ..keySectionData = LoopItem.flattenKeySections(
          const [KeySection(0, 'A#min'), KeySection(156000, 'Bmin')]);
    expect(a.keyLabel, 'A#min → Bmin');
    expect(a.startKey, 'A#min');
    expect(a.endKey, 'Bmin');
    expect(a.keySectionsLabel, '0:00 A#min (3A) → 2:36 Bmin (10A)');
    final b = LoopItem(id: 'b', title: 'b', uri: 'u', sourceType: 'local', musicalKey: 'Bmin');
    // 表示のキー（A#min）なら Bmin と合わないが、終わりは Bmin なので合う
    expect(TrackCompatibility.keyScore(a.endKey, b.startKey), 1.0);
    expect(TrackCompatibility.keyScore(a.musicalKey, b.musicalKey), 0.0);
  });
}
