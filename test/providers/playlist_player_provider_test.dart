import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/playlist_mode.dart';
import 'package:u2b_loop_app/providers/playlist_player_provider.dart';

LoopItem _item(String id, {List<LoopRegion>? regions}) => LoopItem(
      id: id,
      title: '曲$id',
      uri: 'https://example.com/$id',
      sourceType: SourceTypes.youtube,
      videoId: id,
      regions: regions,
    );

/// 区間を2つ持つアイテム（1アイテム＝2トラックに展開される）
LoopItem _itemWithRegions(String id) => _item(id, regions: [
      LoopRegion(id: '${id}_r1', name: '区間 1', pointAMs: 0, pointBMs: 10000),
      LoopRegion(id: '${id}_r2', name: '区間 2', pointAMs: 20000, pointBMs: 30000),
    ]);

void main() {
  group('loadPlaylist', () {
    test('区間なしのアイテムは1トラックになる', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b')]);
      expect(n.currentState.trackCount, 2);
      expect(n.currentState.currentTrack!.item.id, 'a');
    });

    test('区間ありのアイテムは区間の数だけトラックになる', () {
      final n = PlaylistPlayerNotifier()..loadPlaylist([_itemWithRegions('a')]);
      expect(n.currentState.trackCount, 2);
      expect(n.currentState.tracks[0].region!.id, 'a_r1');
      expect(n.currentState.tracks[1].region!.id, 'a_r2');
    });

    test('無効化されたアイテムは展開しない', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b')], disabledItemIds: {'a'});
      expect(n.currentState.trackCount, 1);
      expect(n.currentState.tracks.first.item.id, 'b');
    });

    // 回帰テスト: 空リスト＝スキップ設定。未設定（キー無し）と混同すると
    // スキップしたはずのアイテムが全区間再生されてしまう
    test('区間選択が空リストのアイテムはスキップする', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_itemWithRegions('a'), _item('b')],
            regionSelections: {'a': []});
      expect(n.currentState.trackCount, 1);
      expect(n.currentState.tracks.first.item.id, 'b');
    });

    test('選択された区間だけを展開する', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_itemWithRegions('a')],
            regionSelections: {
              'a': ['a_r2']
            });
      expect(n.currentState.trackCount, 1);
      expect(n.currentState.tracks.first.region!.id, 'a_r2');
    });

    test('initialItemIndex の位置から始まる', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b'), _item('c')],
            initialItemIndex: 2);
      expect(n.currentState.currentTrack!.item.id, 'c');
    });
  });

  group('next / prev', () {
    test('順番に進み、終端では止まる（リピートなし）', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b')]);
      expect(n.next(), isTrue);
      expect(n.currentState.currentTrack!.item.id, 'b');
      expect(n.next(), isFalse, reason: '終端なので進まない');
      expect(n.currentState.currentTrack!.item.id, 'b');
    });

    test('先頭では prev で戻れない', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b')]);
      expect(n.currentState.hasPrev, isFalse);
      expect(n.prev(), isFalse);
      n.next();
      expect(n.currentState.hasPrev, isTrue);
      expect(n.prev(), isTrue);
      expect(n.currentState.currentTrack!.item.id, 'a');
    });

    test('全曲リピートなら終端から先頭へ戻る', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b')]);
      n.cycleRepeatMode(); // none -> all
      expect(n.currentState.repeatMode, RepeatMode.all);
      n.next();
      expect(n.next(), isTrue);
      expect(n.currentState.currentTrack!.item.id, 'a');
    });

    test('単曲リピートは next で移動しない', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b')]);
      n.cycleRepeatMode(); // all
      n.cycleRepeatMode(); // single
      expect(n.currentState.repeatMode, RepeatMode.single);
      expect(n.next(), isFalse);
      expect(n.currentState.currentTrack!.item.id, 'a');
    });

    test('リピートモードは none→all→single→none で一巡する', () {
      final n = PlaylistPlayerNotifier()..loadPlaylist([_item('a')]);
      expect(n.currentState.repeatMode, RepeatMode.none);
      n.cycleRepeatMode();
      expect(n.currentState.repeatMode, RepeatMode.all);
      n.cycleRepeatMode();
      expect(n.currentState.repeatMode, RepeatMode.single);
      n.cycleRepeatMode();
      expect(n.currentState.repeatMode, RepeatMode.none);
    });
  });

  group('peekNextTrackIndex', () {
    test('進む前に次のトラックを言い当てる', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b')]);
      final peeked = n.currentState.peekNextTrackIndex();
      expect(peeked, isNotNull);
      n.next();
      expect(n.currentState.currentTrackIndex, peeked);
    });

    test('終端かつリピートなしなら null', () {
      final n = PlaylistPlayerNotifier()..loadPlaylist([_item('a')]);
      expect(n.currentState.peekNextTrackIndex(), isNull);
    });

    test('無効化したトラックは飛ばす', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b'), _item('c')]);
      n.toggleTrackEnabled(1); // b を無効化
      final peeked = n.currentState.peekNextTrackIndex();
      expect(n.currentState.tracks[peeked!].item.id, 'c');
    });
  });

  group('jumpTo / removeTrack', () {
    test('jumpTo で任意のトラックへ移動する', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b'), _item('c')]);
      n.jumpTo(2);
      expect(n.currentState.currentTrack!.item.id, 'c');
    });

    test('removeTrack でトラックが減る', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist([_item('a'), _item('b'), _item('c')]);
      n.removeTrack(1);
      expect(n.currentState.trackCount, 2);
      expect(n.currentState.tracks.map((t) => t.item.id), ['a', 'c']);
    });
  });

  group('shuffle', () {
    test('シャッフルしてもトラックは増減しない', () {
      final items = List.generate(10, (i) => _item('i$i'));
      final n = PlaylistPlayerNotifier()..loadPlaylist(items);
      n.toggleShuffle();
      expect(n.currentState.shuffle, isTrue);
      expect(n.currentState.trackCount, 10);
      expect(n.currentState.playOrder.toSet(), List.generate(10, (i) => i).toSet(),
          reason: '全トラックが順序に1回ずつ現れること');
    });

    test('シャッフルを戻すと元の順序に戻る', () {
      final n = PlaylistPlayerNotifier()
        ..loadPlaylist(List.generate(5, (i) => _item('i$i')));
      n.toggleShuffle();
      n.toggleShuffle();
      expect(n.currentState.shuffle, isFalse);
      expect(n.currentState.playOrder, [0, 1, 2, 3, 4]);
    });
  });

  group('clear', () {
    test('空にすると currentTrack は null', () {
      final n = PlaylistPlayerNotifier()..loadPlaylist([_item('a')]);
      n.clear();
      expect(n.currentState.isEmpty, isTrue);
      expect(n.currentState.currentTrack, isNull);
      expect(n.currentState.currentTrackIndex, isNull);
    });
  });
}
