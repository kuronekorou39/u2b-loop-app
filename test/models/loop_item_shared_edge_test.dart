import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/audio/shared_edges.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

LoopItem _item({int? leading, int? trailing, int? musicHead, int? musicTail, int? head, int? tail}) =>
    LoopItem(
      id: 'a',
      title: 't',
      uri: 'u',
      sourceType: SourceTypes.local,
      leadingSilenceMs: leading,
      trailingSilenceMs: trailing,
      musicHeadMs: musicHead,
      musicTailMs: musicTail,
      sharedHeadMs: head,
      sharedTailMs: tail,
    );

void main() {
  group('飛ばす長さ', () {
    test('共通の端が一番長ければそれ', () {
      final i = _item(leading: 100, trailing: 300, musicHead: 200, musicTail: 500, head: 4000, tail: 18000);
      expect(i.introSkipMs, 4000);
      expect(i.outroSkipMs, 18000);
    });

    test('無音や曲でない部分のほうが長ければそちら', () {
      final i = _item(leading: 6000, trailing: 25000, tail: 11000);
      expect(i.introSkipMs, 6000);
      expect(i.outroSkipMs, 25000);
    });

    test('曲末がどれも未計測なら null、共通の端だけでも分かる', () {
      expect(_item().outroSkipMs, isNull);
      expect(_item(tail: 11000).outroSkipMs, 11000);
    });
  });

  test('sharedEdge は無ければ none', () {
    expect(_item().sharedEdge, SharedEdge.none);
    expect(_item(head: 1000, tail: 2000).sharedEdge, const SharedEdge(headMs: 1000, tailMs: 2000));
  });

  group('withoutSharedEdges', () {
    final wave = List<double>.filled(100, 0.5);

    test('端の部分だけ無音にしたコピーを返す', () {
      final out = _item(head: 10000, tail: 20000).withoutSharedEdges(wave, 100000);
      expect(out.sublist(0, 10), everyElement(0.0));
      expect(out[10], 0.5);
      expect(out[79], 0.5);
      expect(out.sublist(80), everyElement(0.0));
      expect(wave, everyElement(0.5));
    });

    test('端が無ければ同じものを返す', () {
      expect(identical(_item().withoutSharedEdges(wave, 100000), wave), isTrue);
    });

    test('長さが分からなければそのまま', () {
      expect(identical(_item(tail: 1000).withoutSharedEdges(wave, 0), wave), isTrue);
    });
  });
}
