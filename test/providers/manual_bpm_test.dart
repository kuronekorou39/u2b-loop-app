import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';

/// 手動の BPM 補正（詳細のテンポ編集）: 倍/半分なら拍の格子もその倍率で引き直し、
/// 拍の頭と小節頭は動かない。それ以外の値にしたら格子を捨てる
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  late ProviderContainer container;
  setUp(() async {
    await AppBoxes.loopItems.clear();
    // 120 BPM（1 拍 500ms）、拍 100, 600, …、小節頭 1100
    await AppBoxes.loopItems.put(
      'x',
      LoopItem(
        id: 'x',
        title: 't',
        uri: 'u',
        sourceType: 'local',
        bpm: 120,
        beatBpm: 120,
        beatOffsetMs: 100,
        beatConfidence: 0.8,
        downbeatMs: 1100,
        downbeatConfidence: 0.9,
      ),
    );
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  LoopItem item() => AppBoxes.loopItems.get('x')!;

  test('÷2 にすると格子は半分の BPM で引き直され、小節頭はそのまま拍の頭', () async {
    await container
        .read(loopItemsProvider.notifier)
        .saveAnalysis('x', bpm: 60, musicalKey: null, markAnalyzed: false);
    final grid = item().beatGrid!;
    expect(grid.bpm, closeTo(60, 1e-9));
    expect(grid.downbeatMs, closeTo(1100, 1e-9));
    expect(grid.phaseAt(1100), closeTo(0, 1e-9));
    expect(item().bpm, 60);
    expect(item().downbeatConfidence, 0.9);
  });

  test('×2 にすると元の拍はすべて残る', () async {
    await container
        .read(loopItemsProvider.notifier)
        .saveAnalysis('x', bpm: 240, musicalKey: null, markAnalyzed: false);
    final grid = item().beatGrid!;
    expect(grid.bpm, closeTo(240, 1e-9));
    for (final beat in [100.0, 600.0, 1100.0]) {
      expect(grid.phaseAt(beat), closeTo(0, 1e-6), reason: '$beat');
    }
  });

  test('同じ BPM（0.1 刻みの丸め）なら格子はそのまま', () async {
    await container
        .read(loopItemsProvider.notifier)
        .saveAnalysis('x', bpm: 120.1, musicalKey: null, markAnalyzed: false);
    expect(item().beatBpm, 120);
    expect(item().beatOffsetMs, 100);
  });

  test('倍/半分でない値にしたら格子を捨てる', () async {
    await container
        .read(loopItemsProvider.notifier)
        .saveAnalysis('x', bpm: 100, musicalKey: null, markAnalyzed: false);
    expect(item().beatGrid, isNull);
    expect(item().downbeatMs, isNull);
  });
}
