import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/core/constants.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/services/share_service.dart';

LoopItem _item(
  String videoId, {
  String? title,
  List<LoopRegion>? regions,
  List<String>? tagIds,
}) =>
    LoopItem(
      id: 'id_$videoId',
      title: title ?? '曲 $videoId',
      uri: 'https://youtu.be/$videoId',
      sourceType: SourceTypes.youtube,
      videoId: videoId,
      regions: regions,
      tagIds: tagIds,
    );

void main() {
  group('encode / decode', () {
    test('プレイリスト名と曲が往復する', () {
      final url = ShareService.encode(
        playlistName: 'マイリスト',
        items: [_item('aaaaaaaaaaa'), _item('bbbbbbbbbbb')],
        tagIdToName: {},
      );
      final data = ShareService.decode(url);
      expect(data, isNotNull);
      expect(data!.name, 'マイリスト');
      expect(data.items, hasLength(2));
      expect(data.items.map((i) => i.videoId), ['aaaaaaaaaaa', 'bbbbbbbbbbb']);
    });

    test('AB区間が往復する', () {
      final url = ShareService.encode(
        playlistName: 'PL',
        items: [
          _item('aaaaaaaaaaa', regions: [
            LoopRegion(id: 'r1', name: 'サビ', pointAMs: 45000, pointBMs: 78000),
          ]),
        ],
        tagIdToName: {},
      );
      final data = ShareService.decode(url)!;
      final regions = data.items.first.regions;
      expect(regions, hasLength(1));
      expect(regions.first.name, 'サビ');
      expect(regions.first.pointAMs, 45000);
      expect(regions.first.pointBMs, 78000);
    });

    test('タグ名が往復する', () {
      final url = ShareService.encode(
        playlistName: 'PL',
        items: [_item('aaaaaaaaaaa', tagIds: ['t1', 't2'])],
        tagIdToName: {'t1': '練習中', 't2': 'お気に入り'},
      );
      final data = ShareService.decode(url)!;
      expect(data.items.first.tags, containsAll(['練習中', 'お気に入り']));
    });

    test('日本語・絵文字を含むタイトルが壊れない', () {
      const title = '日本語タイトル 🎵 with ASCII';
      final url = ShareService.encode(
        playlistName: 'PL',
        items: [_item('aaaaaaaaaaa', title: title)],
        tagIdToName: {},
      );
      expect(ShareService.decode(url)!.items.first.title, title);
    });

    test('曲が0件でもデコードできる', () {
      final url = ShareService.encode(
          playlistName: '空', items: [], tagIdToName: {});
      final data = ShareService.decode(url);
      expect(data!.name, '空');
      expect(data.items, isEmpty);
    });
  });

  group('decode の防御', () {
    test('不正なURLは null を返す（例外を投げない）', () {
      expect(ShareService.decode(''), isNull);
      expect(ShareService.decode('https://example.com/'), isNull);
      expect(ShareService.decode('u2bloop://share/not-base64!!'), isNull);
      expect(ShareService.decode('ただの文字列'), isNull);
    });

    test('制御文字は取り除かれる', () {
      // 共有URLは他人から渡ってくるので、表示を壊す制御文字は落とす
      final url = ShareService.encode(
        playlistName: '名\u0000前\u0007あり',
        items: [_item('aaaaaaaaaaa', title: 'タ\u001bイトル')],
        tagIdToName: {},
      );
      final data = ShareService.decode(url)!;
      expect(data.name, '名前あり');
      expect(data.items.first.title, 'タイトル');
    });

    test('前後の空白は落とす', () {
      final url = ShareService.encode(
        playlistName: '  スペース付き  ',
        items: [],
        tagIdToName: {},
      );
      expect(ShareService.decode(url)!.name, 'スペース付き');
    });
  });

  group('QRサイズ判定', () {
    test('少数の曲ならQRに収まる', () {
      expect(
        ShareService.canFitInQr(
            playlistName: 'PL', items: [_item('aaaaaaaaaaa')], tagIdToName: {}),
        isTrue,
      );
    });

    test('推定長は上限と同じ基準で判定される', () {
      final items = List.generate(400, (i) => _item('vid$i'.padRight(11, 'x')));
      final len = ShareService.estimateUrlLength(
          playlistName: 'PL', items: items, tagIdToName: {});
      final fits = ShareService.canFitInQr(
          playlistName: 'PL', items: items, tagIdToName: {});
      expect(fits, len <= AppLimits.qrMaxLength);
    });
  });
}
