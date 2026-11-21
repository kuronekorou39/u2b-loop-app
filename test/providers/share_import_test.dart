import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/models/loop_region.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/services/share_service.dart';

/// 共有リンクの取り込み: もう持っている曲には区間とタグを足す（持っている AB は残す）
void main() {
  late ProviderContainer container;

  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  setUp(() async {
    await AppBoxes.loopItems.clear();
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  LoopItem owned({int a = 0, int b = 0, List<LoopRegion>? regions}) => LoopItem(
        id: 'mine',
        title: '持っている曲',
        uri: '',
        sourceType: SourceTypes.youtube,
        videoId: 'aaaaaaaaaaa',
        pointAMs: a,
        pointBMs: b,
        regions: regions,
      );

  Future<LoopItem> importInto(LoopItem item, List<ShareRegion> shared) async {
    await AppBoxes.loopItems.put(item.id, item);
    final ids = await container
        .read(loopItemsProvider.notifier)
        .importSharedItems(
            [ShareItem(videoId: 'aaaaaaaaaaa', title: '曲', regions: shared)], {});
    expect(ids, ['mine']);
    return AppBoxes.loopItems.get('mine')!;
  }

  test('旧形式の AB しか無い曲に区間を足しても、元の AB は残る', () async {
    final item = await importInto(owned(a: 1000, b: 5000),
        [ShareRegion(name: 'サビ', pointAMs: 8000, pointBMs: 9000)]);
    expect(item.effectiveRegions.map((r) => r.pointAMs), [1000, 8000]);
  });

  test('区間を消した後の曲に足しても ID がぶつからない', () async {
    // 3 つのうち真ん中を消した状態（件数から ID を作ると r2 が重なる）
    final item = await importInto(
      owned(regions: [
        LoopRegion(id: 'mine_r0', name: 'A', pointAMs: 1, pointBMs: 2),
        LoopRegion(id: 'mine_r2', name: 'C', pointAMs: 5, pointBMs: 6),
      ]),
      [ShareRegion(name: 'D', pointAMs: 7, pointBMs: 8)],
    );
    final ids = item.regions.map((r) => r.id).toList();
    expect(ids, hasLength(3));
    expect(ids.toSet(), hasLength(3));
  });

  test('区間の無いリンクでは曲の区間を書き換えない', () async {
    final item = await importInto(owned(a: 1000, b: 5000), const []);
    expect(item.regions, isEmpty);
    expect(item.pointAMs, 1000);
  });
}
