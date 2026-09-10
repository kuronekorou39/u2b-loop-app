import 'package:flutter_test/flutter_test.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';

LoopItem _item({
  int pointAMs = 0,
  int pointBMs = 0,
  List<LoopRegion>? regions,
  String sourceType = SourceTypes.youtube,
}) =>
    LoopItem(
      id: 'i1',
      title: 'テスト曲',
      uri: 'https://example.com/v',
      sourceType: sourceType,
      pointAMs: pointAMs,
      pointBMs: pointBMs,
      regions: regions,
    );

void main() {
  group('ソース種別', () {
    test('isYouTube / isLocal が排他になる', () {
      expect(_item().isYouTube, isTrue);
      expect(_item().isLocal, isFalse);
      final local = _item(sourceType: SourceTypes.local);
      expect(local.isYouTube, isFalse);
      expect(local.isLocal, isTrue);
    });
  });

  group('effectiveRegions', () {
    test('区間があればそのまま返す', () {
      final regions = [LoopRegion(id: 'r1', name: '区間 1', pointAMs: 100)];
      final item = _item(regions: regions);
      expect(item.effectiveRegions, same(regions));
    });

    test('区間もレガシーAB値も無ければ空', () {
      expect(_item().effectiveRegions, isEmpty);
    });

    test('レガシーAB値しか無ければ区間1つとして見せる', () {
      final item = _item(pointAMs: 1000, pointBMs: 5000);
      final effective = item.effectiveRegions;
      expect(effective, hasLength(1));
      expect(effective.first.pointAMs, 1000);
      expect(effective.first.pointBMs, 5000);
    });

    test('B点だけでも区間として見せる', () {
      final item = _item(pointBMs: 5000);
      expect(item.effectiveRegions, hasLength(1));
      expect(item.effectiveRegions.first.pointAMs, isNull);
      expect(item.effectiveRegions.first.pointBMs, 5000);
    });

    // 回帰テスト: 以前は getter が regions を書き換えており、
    // 一覧を描画しただけで区間が生成され、後続のsaveで永続化されていた
    test('読んでも regions を書き換えない（副作用が無い）', () {
      final item = _item(pointAMs: 1000, pointBMs: 5000);
      expect(item.regions, isEmpty);
      item.effectiveRegions;
      item.effectiveRegions;
      expect(item.regions, isEmpty, reason: 'getterがモデルを変更してはいけない');
    });

    test('毎回読んでも同じ内容を返す', () {
      final item = _item(pointAMs: 1000, pointBMs: 5000);
      final a = item.effectiveRegions;
      final b = item.effectiveRegions;
      expect(a.first.pointAMs, b.first.pointAMs);
      expect(a.first.pointBMs, b.first.pointBMs);
    });
  });

  group('ensureRegions', () {
    test('レガシーAB値を区間へ昇格させ、本体リストを返す', () {
      final item = _item(pointAMs: 1000, pointBMs: 5000);
      final regions = item.ensureRegions();
      expect(item.regions, hasLength(1));
      expect(regions, same(item.regions));
      // 返ったリストへの変更が本体に反映される
      regions.first.pointAMs = 2000;
      expect(item.regions.first.pointAMs, 2000);
    });

    test('AB値が無ければ何も作らない', () {
      final item = _item();
      expect(item.ensureRegions(), isEmpty);
      expect(item.regions, isEmpty);
    });

    test('既に区間があれば二重に昇格しない', () {
      final item =
          _item(pointAMs: 1000, regions: [LoopRegion(id: 'r1', name: 'A')]);
      expect(item.ensureRegions(), hasLength(1));
      expect(item.regions, hasLength(1));
    });
  });

  group('playCountThresholdMs', () {
    test('30秒以下は全体を聴いたら1カウント', () {
      expect(LoopItem.playCountThresholdMs(30000), 30000);
      expect(LoopItem.playCountThresholdMs(10000), 10000);
    });

    test('10分以上は8分固定', () {
      expect(LoopItem.playCountThresholdMs(600000), 480000);
      expect(LoopItem.playCountThresholdMs(3600000), 480000);
    });

    test('その間は80%', () {
      expect(LoopItem.playCountThresholdMs(100000), 80000);
      expect(LoopItem.playCountThresholdMs(300000), 240000);
    });

    test('しきい値は曲の長さを超えない', () {
      for (final d in [1000, 30000, 30001, 100000, 599999, 600000]) {
        expect(LoopItem.playCountThresholdMs(d), lessThanOrEqualTo(d),
            reason: '長さ${d}msでしきい値が曲より長い');
      }
    });
  });

  group('取得状態', () {
    test('fetchStatus で状態を判定する', () {
      final item = _item();
      expect(item.isReady, isTrue);
      expect(item.isFetching, isFalse);
      expect(item.hasError, isFalse);

      item.fetchStatus = 'fetching';
      expect(item.isFetching, isTrue);
      expect(item.isReady, isFalse);

      item.fetchStatus = 'error:取得に失敗';
      expect(item.hasError, isTrue);
      expect(item.errorMessage, '取得に失敗');
    });
  });

  group('オフラインキャッシュ', () {
    test('cachedVideoPath の有無で isCached が決まる', () {
      final item = _item();
      expect(item.isCached, isFalse);
      item.cachedVideoPath = '/data/x.mp4';
      expect(item.isCached, isTrue);
    });
  });
}
