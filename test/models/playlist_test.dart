import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/playlist.dart';

LoopItem _song(String id, List<String> tags, {bool ready = true}) => LoopItem(
      id: id,
      title: id,
      uri: id,
      sourceType: SourceTypes.youtube,
      tagIds: tags,
      fetchStatus: ready ? null : 'fetching',
    );

void main() {
  group('effectiveThumbnailItemId', () {
    test('明示設定があればそれを使う', () {
      final pl = Playlist(
        id: 'p1',
        name: 'PL',
        itemIds: ['a', 'b'],
        thumbnailItemId: 'b',
      );
      expect(pl.effectiveThumbnailItemId, 'b');
    });

    test('未設定なら先頭のアイテム', () {
      final pl = Playlist(id: 'p1', name: 'PL', itemIds: ['a', 'b']);
      expect(pl.effectiveThumbnailItemId, 'a');
    });

    test('空のプレイリストは null', () {
      final pl = Playlist(id: 'p1', name: 'PL');
      expect(pl.effectiveThumbnailItemId, isNull);
    });
  });

  group('既定値', () {
    test('リストとマップは空で初期化される（null にならない）', () {
      final pl = Playlist(id: 'p1', name: 'PL');
      expect(pl.itemIds, isEmpty);
      expect(pl.regionSelections, isEmpty);
      expect(pl.disabledItemIds, isEmpty);
      expect(pl.defaultShuffle, isFalse);
      expect(pl.createdAt, isNotNull);
    });
  });

  group('区間選択の意味', () {
    // キー無し＝未設定（全区間再生）、空リスト＝スキップ。
    // 混同するとスキップ設定が「全区間選択」に化ける
    test('キーの有無と空リストは別の意味を持つ', () {
      final pl = Playlist(id: 'p1', name: 'PL', itemIds: ['a', 'b']);
      pl.regionSelections['b'] = [];
      expect(pl.regionSelections.containsKey('a'), isFalse, reason: '未設定');
      expect(pl.regionSelections.containsKey('b'), isTrue);
      expect(pl.regionSelections['b'], isEmpty, reason: 'スキップ設定');
    });
  });

  group('タグで自動追加（syncTagItems）', () {
    test('どれかのタグが付いた曲を末尾に足す（OR）。取得中の曲は入れない', () {
      final pl = Playlist(id: 'p', name: 'PL', itemIds: ['m'], tagIds: ['rock', 'jazz']);
      final changed = pl.syncTagItems([
        _song('m', []),
        _song('a', ['rock']),
        _song('b', ['pop']),
        _song('c', ['jazz', 'rock']),
        _song('d', ['rock'], ready: false),
      ]);
      expect(changed, isTrue);
      expect(pl.itemIds, ['m', 'a', 'c']);
      expect(pl.tagItemIds, {'a', 'c'});
    });

    test('タグが外れた曲は抜く。手で足した曲は残す', () {
      final pl = Playlist(id: 'p', name: 'PL', tagIds: ['rock']);
      pl.syncTagItems([_song('a', ['rock'])]);
      pl.itemIds.add('m'); // 手で足した（tagItemIds に入らない）
      final changed = pl.syncTagItems([_song('a', []), _song('m', [])]);
      expect(changed, isTrue);
      expect(pl.itemIds, ['m']);
      expect(pl.tagItemIds, isEmpty);
    });

    test('外した曲は戻さない。タグが外れたら外した印も消える', () {
      final pl = Playlist(id: 'p', name: 'PL', tagIds: ['rock'], excludedItemIds: {'a'});
      pl.syncTagItems([_song('a', ['rock'])]);
      expect(pl.itemIds, isEmpty);
      pl.syncTagItems([_song('a', [])]);
      expect(pl.excludedItemIds, isEmpty);
    });

    test('変わらなければ false', () {
      final pl = Playlist(id: 'p', name: 'PL', tagIds: ['rock']);
      pl.syncTagItems([_song('a', ['rock'])]);
      expect(pl.syncTagItems([_song('a', ['rock'])]), isFalse);
      expect(Playlist(id: 'q', name: 'Q').syncTagItems([_song('a', ['rock'])]),
          isFalse);
    });
  });
}
