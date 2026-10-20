import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/models/playlist.dart';
import 'package:u2b_loop_app/models/tag.dart';
import 'package:u2b_loop_app/services/backup_service.dart';

LoopItem _item(String id) => LoopItem(
      id: id,
      title: '曲 $id',
      uri: 'https://youtu.be/$id',
      sourceType: SourceTypes.youtube,
      videoId: id,
      speed: 1.25,
      memo: 'メモ',
      tagIds: ['t1'],
      regions: [
        LoopRegion(id: '${id}_r1', name: 'サビ', pointAMs: 1000, pointBMs: 5000),
      ],
      playCount: 7,
      hasSubtitles: true,
      createdAt: DateTime(2026, 1, 2, 3, 4, 5),
      updatedAt: DateTime(2026, 2, 3, 4, 5, 6),
    );

BackupData _roundTrip({
  List<LoopItem> items = const [],
  List<Playlist> playlists = const [],
  List<Tag> tags = const [],
}) =>
    BackupService.decode(
        BackupService.encode(items: items, playlists: playlists, tags: tags));

void main() {
  group('往復（encode → decode）', () {
    test('アイテムの中身が保たれる', () {
      final back = _roundTrip(items: [_item('a')]).items.single;
      expect(back.id, 'a');
      expect(back.title, '曲 a');
      expect(back.speed, 1.25);
      expect(back.memo, 'メモ');
      expect(back.tagIds, ['t1']);
      expect(back.playCount, 7);
      expect(back.hasSubtitles, isTrue);
      expect(back.isYouTube, isTrue);
      expect(back.regions.single.name, 'サビ');
      expect(back.regions.single.pointAMs, 1000);
      expect(back.regions.single.pointBMs, 5000);
    });

    test('手で直した 1 番の範囲が保たれる', () {
      final item = _item('a')
        ..firstVerseAMs = 2000
        ..firstVerseBMs = 65000;
      final back = _roundTrip(items: [item]).items.single;
      expect(back.firstVerseAMs, 2000);
      expect(back.firstVerseBMs, 65000);
      expect(back.hasFirstVerse, isTrue);
      expect(_roundTrip(items: [_item('b')]).items.single.hasFirstVerse, isFalse);
    });

    test('日時が保たれる', () {
      final back = _roundTrip(items: [_item('a')]).items.single;
      expect(back.createdAt, DateTime(2026, 1, 2, 3, 4, 5));
      expect(back.updatedAt, DateTime(2026, 2, 3, 4, 5, 6));
    });

    // 回帰テスト: 以前はバックアップに含めておらず、復元でサムネ設定が消えていた
    test('プレイリストのサムネイル指定が保たれる', () {
      final pl = Playlist(
          id: 'p1', name: 'PL', itemIds: ['a', 'b'], thumbnailItemId: 'b');
      final back = _roundTrip(playlists: [pl]).playlists.single;
      expect(back.thumbnailItemId, 'b');
    });

    // キー無し＝未設定、空リスト＝スキップ。復元で区別が消えてはいけない
    test('区間選択の「空リスト（スキップ）」が保たれる', () {
      final pl = Playlist(
        id: 'p1',
        name: 'PL',
        itemIds: ['a', 'b'],
        regionSelections: {
          'a': ['a_r1'],
          'b': [],
        },
      );
      final back = _roundTrip(playlists: [pl]).playlists.single;
      expect(back.regionSelections['a'], ['a_r1']);
      expect(back.regionSelections.containsKey('b'), isTrue);
      expect(back.regionSelections['b'], isEmpty);
    });

    test('無効化アイテムとシャッフル既定が保たれる', () {
      final pl = Playlist(
        id: 'p1',
        name: 'PL',
        itemIds: ['a', 'b'],
        disabledItemIds: {'b'},
        defaultShuffle: true,
      );
      final back = _roundTrip(playlists: [pl]).playlists.single;
      expect(back.disabledItemIds, {'b'});
      expect(back.defaultShuffle, isTrue);
    });

    test('タグが保たれる', () {
      final back =
          _roundTrip(tags: [Tag(id: 't1', name: '練習中', colorIndex: 3)])
              .tags
              .single;
      expect(back.name, '練習中');
      expect(back.colorIndex, 3);
    });

    test('端末固有のパスは含めない', () {
      final item = _item('a')
        ..thumbnailPath = '/data/thumb.jpg'
        ..cachedVideoPath = '/data/video.mp4';
      final json = BackupService.encode(items: [item], playlists: [], tags: []);
      expect(json, isNot(contains('/data/thumb.jpg')));
      expect(json, isNot(contains('/data/video.mp4')));
      final back = BackupService.decode(json).items.single;
      expect(back.thumbnailPath, isNull);
      expect(back.isCached, isFalse);
    });
  });

  group('古いバックアップとの互換', () {
    test('後から足した項目が無くても既定値で読める', () {
      final old = jsonEncode({
        'version': 1,
        'items': [
          {'id': 'a', 'title': 't', 'uri': 'u', 'sourceType': 'youtube'},
        ],
        'playlists': [
          {'id': 'p1', 'name': 'PL', 'itemIds': ['a']},
        ],
        'tags': [
          {'id': 't1', 'name': 'タグ'},
        ],
      });
      final data = BackupService.decode(old);
      final item = data.items.single;
      expect(item.speed, 1.0);
      expect(item.playCount, 0);
      expect(item.regions, isEmpty);
      expect(item.hasSubtitles, isNull);
      final pl = data.playlists.single;
      expect(pl.thumbnailItemId, isNull);
      expect(pl.defaultShuffle, isFalse);
      expect(pl.regionSelections, isEmpty);
      expect(data.tags.single.colorIndex, 0);
    });

    test('セクションごと無くても空として読める', () {
      final data = BackupService.decode('{"version": 1}');
      expect(data.items, isEmpty);
      expect(data.playlists, isEmpty);
      expect(data.tags, isEmpty);
    });
  });

  // decode は純粋関数なので、壊れた入力で例外になっても既存データは無事。
  // 復元（restore）は decode が成功した後にしか呼ばれない。
  group('壊れた入力', () {
    test('JSONでなければ FormatException', () {
      expect(() => BackupService.decode('これはJSONではない'),
          throwsA(isA<FormatException>()));
    });

    test('ルートがオブジェクトでなければ FormatException', () {
      expect(() => BackupService.decode('[1, 2, 3]'),
          throwsA(isA<FormatException>()));
    });

    test('必須項目が欠けたアイテムが1件でもあれば全体を拒否する', () {
      final broken = jsonEncode({
        'items': [
          {'id': 'a', 'title': 't', 'uri': 'u', 'sourceType': 'youtube'},
          {'id': 'b'}, // title などが無い
        ],
      });
      expect(() => BackupService.decode(broken),
          throwsA(isA<FormatException>()));
    });
  });

  group('ファイル名', () {
    test('日時入りでファイル名に使えない文字を含まない', () {
      final name = BackupService.fileName(DateTime(2026, 9, 11, 10, 20, 30));
      expect(name, 'u2b_loop_backup_2026-09-11T10-20-30.json');
      expect(name, isNot(contains(':')));
    });
  });
}
