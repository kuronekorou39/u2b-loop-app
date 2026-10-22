import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/bulk_analysis_provider.dart';

/// まとめて解析: 裏で 1 曲ずつ進み、中止・消された曲・先に解析済みの曲を扱う
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  late List<LoopItem> items;
  setUp(() async {
    await AppBoxes.loopItems.clear();
    items = [
      for (var i = 0; i < 3; i++)
        LoopItem(id: 'i$i', title: '曲$i', uri: 'u$i', sourceType: 'local'),
    ];
    for (final i in items) {
      await AppBoxes.loopItems.put(i.id, i);
    }
  });

  void markAnalyzed(LoopItem item) {
    item
      ..analyzedAt = 1
      ..leadingSilenceMs = 0
      ..analysisVersion = LoopItem.currentAnalysisVersion;
  }

  /// 1 曲ずつ手で進められる解析。[gates] の i 番を complete すると i 曲目が終わる
  (ProviderContainer, BulkAnalysisNotifier, List<Completer<bool>>) setUpJob() {
    final gates = <Completer<bool>>[];
    final container = ProviderContainer(overrides: [
      bulkAnalysisProvider.overrideWith((ref) => BulkAnalysisNotifier(ref,
          analyze: (item) {
        final c = Completer<bool>();
        gates.add(c);
        return c.future.then((ok) {
          if (ok) markAnalyzed(AppBoxes.loopItems.get(item.id)!);
          return ok;
        });
      })),
    ]);
    addTearDown(container.dispose);
    return (container, container.read(bulkAnalysisProvider.notifier), gates);
  }

  test('1 曲ずつ進み、進み具合が見え、終わると止まる', () async {
    final (c, job, gates) = setUpJob();
    expect(job.start('pl', items), isTrue);
    expect(job.start('pl', items), isFalse, reason: '2 つ目は始めない');
    await pumpEventQueue();
    expect(c.read(bulkAnalysisProvider)!.currentId, 'i0');
    gates[0].complete(true);
    await pumpEventQueue();
    expect(c.read(bulkAnalysisProvider)!.index, 1);
    expect(c.read(bulkAnalysisProvider)!.currentTitle, '曲1');
    gates[1].complete(true);
    await pumpEventQueue();
    gates[2].complete(false);
    await pumpEventQueue();
    expect(c.read(bulkAnalysisProvider), isNull);
    expect(job.lastResult,
        (done: 2, skipped: 0, failed: 1, cancelled: false));
  });

  test('中止はいまの曲が終わってから', () async {
    final (c, job, gates) = setUpJob();
    job.start('pl', items);
    await pumpEventQueue();
    job.stop();
    expect(c.read(bulkAnalysisProvider)!.stopping, isTrue);
    gates[0].complete(true);
    await pumpEventQueue();
    expect(c.read(bulkAnalysisProvider), isNull);
    expect(gates, hasLength(1));
    expect(job.lastResult!.cancelled, isTrue);
  });

  test('途中で消された曲は飛ばし、先に解析された曲は解析し直さない', () async {
    final (_, job, gates) = setUpJob();
    job.start('pl', items);
    await pumpEventQueue();
    // 解析中に 2 曲目が再生側で解析され、3 曲目が消された
    markAnalyzed(AppBoxes.loopItems.get('i1')!);
    await AppBoxes.loopItems.delete('i2');
    gates[0].complete(true);
    await pumpEventQueue();
    expect(gates, hasLength(1));
    expect(job.lastResult,
        (done: 2, skipped: 0, failed: 0, cancelled: false));
  });
}
