import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/playlist.dart';

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
}
