import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/shared_edges.dart';
import 'package:u2b_loop_app/core/audio/wave_bands.dart';

const _perSec = 20; // WaveBands の既定（50ms）

Uint8List _noise(int seed, int n) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => 40 + r.nextInt(180)));
}

/// 3 帯域ぶんの音（それぞれ別の乱数）
List<Uint8List> _sound(int seed, int seconds) =>
    [for (var b = 0; b < 3; b++) _noise(seed * 10 + b, seconds * _perSec)];

List<Uint8List> _join(List<Uint8List> a, List<Uint8List> b) => [
      for (var c = 0; c < 3; c++) Uint8List.fromList([...a[c], ...b[c]]),
    ];

List<Uint8List> _silence(int points) => [for (var c = 0; c < 3; c++) Uint8List(points)];

/// 本体 [seconds] 秒の頭に [head]、末尾に [tail] を付けた曲
EdgeBands _song(String id, int seed,
    {int seconds = 120, List<Uint8List>? head, List<Uint8List>? tail}) {
  var s = _sound(seed, seconds);
  if (head != null) s = _join(head, s);
  if (tail != null) s = _join(s, tail);
  return EdgeBands.of(id, WaveBands(stepMs: 50, low: s[0], mid: s[1], high: s[2]));
}

void main() {
  final card = _sound(99, 15);

  group('find', () {
    test('3 曲に共通の終わりは、その長さぶん端になる', () {
      final all = [
        _song('a', 1, tail: card),
        _song('b', 2, tail: card),
        _song('c', 3, tail: card),
      ];
      for (final e in all) {
        final r = SharedEdges.find(e, all);
        expect(r.tailMs, 15000);
        expect(r.headMs, 0);
      }
    });

    test('2 曲だけの一致は端にしない（同じ曲の別の動画かもしれない）', () {
      final all = [
        _song('a', 1, tail: card),
        _song('b', 2, tail: card),
        _song('c', 3),
      ];
      expect(SharedEdges.find(all[0], all), SharedEdge.none);
      expect(SharedEdges.find(all[2], all), SharedEdge.none);
    });

    test('カードの無い曲どうしは何も見つけない', () {
      final all = [_song('a', 1), _song('b', 2), _song('c', 3), _song('d', 4)];
      for (final e in all) {
        expect(SharedEdges.find(e, all), SharedEdge.none);
      }
    });

    test('同じ曲の別の動画が 3 本あっても、曲を端にしない', () {
      final body = _sound(7, 90);
      EdgeBands video(String id) =>
          EdgeBands.of(id, WaveBands(stepMs: 50, low: body[0], mid: body[1], high: body[2]));
      final all = [video('a'), video('b'), video('c')];
      expect(SharedEdges.find(all[0], all), SharedEdge.none);
    });

    test('丸ごと同じ短い動画は端にしない', () {
      final body = _sound(7, 30);
      EdgeBands video(String id) =>
          EdgeBands.of(id, WaveBands(stepMs: 50, low: body[0], mid: body[1], high: body[2]));
      final all = [video('a'), video('b'), video('c')];
      expect(SharedEdges.find(all[0], all), SharedEdge.none);
    });

    test('動画ごとに末尾の無音の長さが違っても見つける', () {
      final all = [
        _song('a', 1, tail: card),
        _song('b', 2, tail: _join(card, _silence(_perSec))),
        _song('c', 3, tail: _join(card, _silence(_perSec * 2))),
      ];
      expect(SharedEdges.find(all[0], all).tailMs, 15000);
      expect(SharedEdges.find(all[1], all).tailMs, 16000);
      expect(SharedEdges.find(all[2], all).tailMs, 17000);
    });

    test('カードの部分ごとに動画間のずれが違っても、全体を端にする', () {
      final outer = _sound(50, 11), inner = _sound(51, 7);
      final plain = _join(inner, outer);
      // c だけ 2 つの部分の間に 400ms の間がある
      final gapped = _join(_join(inner, _silence(8)), outer);
      final all = [
        _song('a', 1, tail: plain),
        _song('b', 2, tail: plain),
        _song('c', 3, tail: gapped),
      ];
      expect(SharedEdges.find(all[0], all).tailMs, 18000);
    });

    test('3 曲に共通の頭も見つける', () {
      final logo = _sound(60, 8);
      final all = [
        _song('a', 1, head: logo),
        _song('b', 2, head: logo),
        _song('c', 3, head: logo),
      ];
      final r = SharedEdges.find(all[0], all);
      expect(r.headMs, 8000);
      expect(r.tailMs, 0);
    });

    test('短すぎる一致は偶然として数えない', () {
      final short = _sound(70, 3);
      final all = [
        _song('a', 1, tail: short),
        _song('b', 2, tail: short),
        _song('c', 3, tail: short),
      ];
      expect(SharedEdges.find(all[0], all), SharedEdge.none);
    });
  });

  group('refresh', () {
    test('3 曲目が来たら、前からある曲の端も返す', () {
      final a = _song('a', 1, tail: card), b = _song('b', 2, tail: card);
      expect(SharedEdges.refresh(b, [a, b], const {}), isEmpty);
      final c = _song('c', 3, tail: card);
      final changes = SharedEdges.refresh(c, [a, b, c], const {});
      expect(changes.keys.toSet(), {'a', 'b', 'c'});
      expect(changes['a']!.tailMs, 15000);
    });

    test('端が分かっている曲は、同じカードの曲が増えても変えない', () {
      const known = SharedEdge(tailMs: 15000);
      final a = _song('a', 1, tail: card),
          b = _song('b', 2, tail: card),
          c = _song('c', 3, tail: card),
          d = _song('d', 4, tail: card);
      final changes = SharedEdges.refresh(d, [a, b, c, d], {'a': known, 'b': known, 'c': known});
      expect(changes.keys, ['d']);
    });

    test('関係のない曲が増えても何も変えない', () {
      const known = SharedEdge(tailMs: 15000);
      final a = _song('a', 1, tail: card),
          b = _song('b', 2, tail: card),
          c = _song('c', 3, tail: card),
          d = _song('d', 4);
      expect(SharedEdges.refresh(d, [a, b, c, d], {'a': known, 'b': known, 'c': known}), isEmpty);
    });
  });

  group('muted', () {
    final pcm = Int16List.fromList(List.filled(1000, 500));

    test('端を無音にしたコピーを返し、元は変えない', () {
      final out = SharedEdges.muted(pcm, 100, const SharedEdge(headMs: 1000, tailMs: 2000));
      expect(out.sublist(0, 100).every((v) => v == 0), isTrue);
      expect(out[100], 500);
      expect(out[799], 500);
      expect(out.sublist(800).every((v) => v == 0), isTrue);
      expect(pcm.every((v) => v == 500), isTrue);
    });

    test('端が無ければそのまま', () {
      expect(identical(SharedEdges.muted(pcm, 100, SharedEdge.none), pcm), isTrue);
    });
  });
}
