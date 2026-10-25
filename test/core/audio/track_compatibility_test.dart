import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/track_compatibility.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

LoopItem _item(String id,
        {double? bpm, String? key, double? headDb, double? tailDb}) =>
    LoopItem(
      id: id,
      title: id,
      uri: 'https://example.com/$id',
      sourceType: SourceTypes.youtube,
      videoId: id,
      bpm: bpm,
      musicalKey: key,
      headDb: headDb,
      tailDb: tailDb,
    );

void main() {
  group('tempoRatio', () {
    test('同じテンポなら 1', () {
      expect(TrackCompatibility.tempoRatio(120, 120), closeTo(1.0, 1e-9));
    });

    test('倍/半テンポは同一視する', () {
      expect(TrackCompatibility.tempoRatio(120, 60), closeTo(1.0, 1e-9));
      expect(TrackCompatibility.tempoRatio(60, 120), closeTo(1.0, 1e-9));
      // 126 を 120 に寄せる: 240 とみなしても 0.95 のほうが 1 に近い
      expect(TrackCompatibility.tempoRatio(120, 126), closeTo(120 / 126, 1e-9));
      expect(TrackCompatibility.tempoRatio(120, 252), closeTo(120 / 126, 1e-9));
    });

    test('どちらか不明なら null', () {
      expect(TrackCompatibility.tempoRatio(null, 120), isNull);
      expect(TrackCompatibility.tempoRatio(120, null), isNull);
      expect(TrackCompatibility.tempoRatio(120, 0), isNull);
    });

    test('差は % で取り出せる', () {
      expect(TrackCompatibility.tempoDiffPercent(100, 105), closeTo(4.76, 0.01));
      expect(TrackCompatibility.tempoDiffPercent(100, 210), closeTo(4.76, 0.01));
    });
  });

  group('score', () {
    test('テンポもキーも合う曲が最も高い', () {
      final a = _item('a', bpm: 120, key: 'Amin');
      final good = _item('g', bpm: 121, key: 'Cmaj'); // 平行調
      final tempoOnly = _item('t', bpm: 121, key: 'F#maj'); // 遠いキー
      final keyOnly = _item('k', bpm: 150, key: 'Amin');
      final sGood = TrackCompatibility.score(a, good);
      // 音量の流れが未計測（中立値 0.35 × 0.2）なので上限は 0.87
      expect(sGood, greaterThan(0.8));
      expect(sGood, greaterThan(TrackCompatibility.score(a, tempoOnly)));
      expect(sGood, greaterThan(TrackCompatibility.score(a, keyOnly)));
    });

    test('未解析は中立値で、合う曲より低く合わない曲より高い', () {
      final a = _item('a', bpm: 120, key: 'Amin');
      final unknown = _item('u');
      final bad = _item('b', bpm: 150, key: 'F#maj');
      final good = _item('g', bpm: 120, key: 'Amin');
      final s = TrackCompatibility.score(a, unknown);
      expect(s, closeTo(TrackCompatibility.unknownScore, 1e-9));
      expect(s, lessThan(TrackCompatibility.score(a, good)));
      expect(s, greaterThan(TrackCompatibility.score(a, bad)));
    });

    test('音量の流れ: 終わりと頭の dB が近いほど高く、3dB までは満点、未計測は中立値', () {
      final loudEnd = _item('a', bpm: 120, key: 'Amin', tailDb: -6);
      final loudHead = _item('l', bpm: 120, key: 'Amin', headDb: -8);
      final quietHead = _item('q', bpm: 120, key: 'Amin', headDb: -20);
      final unknown = _item('u', bpm: 120, key: 'Amin');
      expect(TrackCompatibility.flowScore(loudEnd, loudHead), 1.0);
      expect(TrackCompatibility.flowScore(loudEnd, quietHead),
          closeTo(1 - 11 / 12, 1e-9));
      expect(TrackCompatibility.flowScore(loudEnd, unknown),
          TrackCompatibility.unknownScore);
      // テンポ・キーが同じなら、流れがつながる曲が前に来る
      expect(TrackCompatibility.score(loudEnd, loudHead),
          greaterThan(TrackCompatibility.score(loudEnd, quietHead)));
      expect(TrackCompatibility.rank(loudEnd, [quietHead, loudHead]).first.id, 'l');
    });

    test('キーは Camelot で2つ離れると部分点、それ以上は0', () {
      expect(TrackCompatibility.keyScore('Cmaj', 'Gmaj'), 1.0); // 8B-9B
      expect(TrackCompatibility.keyScore('Cmaj', 'Dmaj'), 0.4); // 8B-10B
      expect(TrackCompatibility.keyScore('Cmaj', 'F#maj'), 0.0); // 8B-2B
      expect(TrackCompatibility.keyScore('Cmaj', null),
          TrackCompatibility.unknownScore);
    });
  });

  group('order', () {
    test('先頭を固定し、直前と相性のよい順につなぐ', () {
      final items = [
        _item('start', bpm: 120, key: 'Amin'),
        _item('far', bpm: 160, key: 'F#maj'),
        _item('near', bpm: 122, key: 'Cmaj'),
        _item('mid', bpm: 128, key: 'Emin'),
      ];
      final ordered = TrackCompatibility.order(items);
      expect(ordered.map((e) => e.id), ['start', 'near', 'mid', 'far']);
    });

    test('未解析の曲は元の順のまま末尾に回す', () {
      final items = [
        _item('u1'),
        _item('a', bpm: 120, key: 'Amin'),
        _item('u2'),
        _item('b', bpm: 121, key: 'Amin'),
      ];
      final ordered = TrackCompatibility.order(items, startIndex: 1);
      expect(ordered.map((e) => e.id), ['a', 'b', 'u1', 'u2']);
    });

    test('1曲以下はそのまま', () {
      expect(TrackCompatibility.order([]), isEmpty);
      final one = _item('a', bpm: 100);
      expect(TrackCompatibility.order([one]).single.id, 'a');
    });
  });

  group('rank / describe', () {
    test('自分自身と未解析は除き、相性順に並ぶ', () {
      final target = _item('t', bpm: 120, key: 'Amin');
      final ranked = TrackCompatibility.rank(target, [
        target,
        _item('u'),
        _item('far', bpm: 170, key: 'F#maj'),
        _item('near', bpm: 118, key: 'Emin'),
      ]);
      expect(ranked.map((e) => e.id), ['near', 'far']);
    });

    test('説明文にテンポ差とキー相性が出る', () {
      final target = _item('t', bpm: 120, key: 'Amin');
      expect(TrackCompatibility.describe(target, _item('o', bpm: 126, key: 'Cmaj')),
          '126 BPM (+5%) · Cmaj (8B) ✓');
      expect(TrackCompatibility.describe(target, _item('o', bpm: 60, key: 'F#maj')),
          '60 BPM (±0%) · F#maj (2B)');
    });
  });
}
