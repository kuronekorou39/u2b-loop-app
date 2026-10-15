import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/utils/add_input.dart';
import 'package:u2b_loop_app/core/utils/item_filter.dart';
import 'package:u2b_loop_app/models/loop_item.dart';

/// ホームの絞り込み・並び替えと、「追加」入力の判定（画面から切り出した純粋関数）
void main() {
  LoopItem item(String id,
          {List<String> tags = const [],
          String? memo,
          int playCount = 0,
          DateTime? updated,
          DateTime? created}) =>
      LoopItem(
        id: id,
        title: id,
        uri: 'u',
        sourceType: 'local',
        tagIds: tags,
        memo: memo,
        playCount: playCount,
        updatedAt: updated,
        createdAt: created,
      );

  final rock = item('rock', tags: ['r']);
  final rockJazz = item('rockjazz', tags: ['r', 'j']);
  final jazz = item('jazz', tags: ['j']);
  final none = item('none');
  final all = [rock, rockJazz, jazz, none];

  List<String> ids(List<LoopItem> l) => l.map((i) => i.id).toList();

  group('ItemFilter.byTags', () {
    test('無指定なら全部', () {
      expect(ItemFilter.byTags(all, {}), all);
    });

    test('含む（true）は指定したタグをすべて持つもの', () {
      expect(ids(ItemFilter.byTags(all, {'r': true})), ['rock', 'rockjazz']);
      expect(ids(ItemFilter.byTags(all, {'r': true, 'j': true})), ['rockjazz']);
    });

    test('除外（false）は 1 つでも持っていれば外す。除外だけなら残りは全部', () {
      expect(ids(ItemFilter.byTags(all, {'j': false})), ['rock', 'none']);
      expect(ids(ItemFilter.byTags(all, {'r': true, 'j': false})), ['rock']);
    });

    test('未分類は untaggedId で含む / 除外', () {
      expect(ids(ItemFilter.byTags(all, {ItemFilter.untaggedId: true})), ['none']);
      expect(ids(ItemFilter.byTags(all, {ItemFilter.untaggedId: false})),
          ['rock', 'rockjazz', 'jazz']);
      // 未分類 + タグ含む は「どちらか」
      expect(ids(ItemFilter.byTags(all, {ItemFilter.untaggedId: true, 'j': true})),
          ['rockjazz', 'jazz', 'none']);
    });
  });

  group('ItemFilter.bySearch', () {
    test('曲名とメモの部分一致、大文字小文字を区別しない、前後の空白は無視', () {
      final list = [item('Hello', memo: 'world'), item('other', memo: 'xyz')];
      expect(ids(ItemFilter.bySearch(list, 'HELLO')), ['Hello']);
      expect(ids(ItemFilter.bySearch(list, ' wor ')), ['Hello']);
      expect(ids(ItemFilter.bySearch(list, '')), ['Hello', 'other']);
      expect(ItemFilter.bySearch(list, 'nothing'), isEmpty);
    });
  });

  group('ItemFilter.sorted', () {
    final t0 = DateTime(2026, 1, 1);
    final a = item('a', updated: t0, created: t0.add(const Duration(days: 2)), playCount: 1);
    final b = item('b', updated: t0.add(const Duration(days: 1)), created: t0, playCount: 5);
    final c = item('c', updated: t0.add(const Duration(days: 2)), created: t0.add(const Duration(days: 1)));

    test('更新日・作成日・タイトル・再生回数', () {
      expect(ids(ItemFilter.sorted([a, b, c], ItemSortMode.updatedDesc)), ['c', 'b', 'a']);
      expect(ids(ItemFilter.sorted([a, b, c], ItemSortMode.updatedAsc)), ['a', 'b', 'c']);
      expect(ids(ItemFilter.sorted([a, b, c], ItemSortMode.createdDesc)), ['a', 'c', 'b']);
      expect(ids(ItemFilter.sorted([c, a, b], ItemSortMode.titleAsc)), ['a', 'b', 'c']);
      expect(ids(ItemFilter.sorted([a, b, c], ItemSortMode.titleDesc)), ['c', 'b', 'a']);
      expect(ids(ItemFilter.sorted([a, b, c], ItemSortMode.playCountDesc)), ['b', 'a', 'c']);
    });

    test('元のリストは並べ替えない', () {
      final src = [b, a];
      ItemFilter.sorted(src, ItemSortMode.titleAsc);
      expect(ids(src), ['b', 'a']);
    });
  });

  group('AddInput.parse', () {
    test('空・共有 URL・不正', () {
      expect(AddInput.parse('   '), isA<AddInputEmpty>());
      expect(AddInput.parse('u2bloop://abc'), isA<AddInputShare>());
      expect(AddInput.parse('https://example.com/x'), isA<AddInputInvalid>());
    });

    test('動画 / プレイリスト / 両方', () {
      final v = AddInput.parse('https://youtu.be/dQw4w9WgXcQ');
      expect(v, isA<AddInputVideo>());
      expect((v as AddInputVideo).videoId, 'dQw4w9WgXcQ');

      final p = AddInput.parse(
          'https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf');
      expect(p, isA<AddInputPlaylist>());

      final both = AddInput.parse(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf');
      expect(both, isA<AddInputVideoInPlaylist>());
      expect((both as AddInputVideoInPlaylist).videoId, 'dQw4w9WgXcQ');
      expect(both.playlistId, 'PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf');
    });
  });
}
