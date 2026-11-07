import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/key_sections.dart';
import 'package:u2b_loop_app/core/audio/tempo_sections.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/services/audio_analysis_service.dart';
import 'package:u2b_loop_app/widgets/tempo_key_sheet.dart';

/// テンポ/キーの手直し: 区切りごとに値を直す
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
    // 0:00〜1:00 が 50 BPM、1:00〜3:20 が 75 BPM（メイン）。キーは 2:36 で A#min → Bmin
    await AppBoxes.loopItems.put(
      'x',
      LoopItem(
        id: 'x',
        title: 't',
        uri: 'u',
        sourceType: 'local',
        durationMs: 200000,
        bpm: 75,
        musicalKey: 'A#min',
        beatBpm: 75,
        beatOffsetMs: 100,
        beatConfidence: 0.8,
        tempoSectionData: TempoSection.flatten(
            const [TempoSection(0, 50), TempoSection(60000, 75)]),
        sectionGridData: LoopItem.flattenGrids(const [
          BeatGrid(bpm: 50, offsetMs: 0, confidence: 0.7),
          BeatGrid(bpm: 75, offsetMs: 100, confidence: 0.8),
        ]),
        keySectionData: LoopItem.flattenKeySections(
            const [KeySection(0, 'A#min'), KeySection(156000, 'Bmin')]),
      ),
    );
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  LoopItem item() => AppBoxes.loopItems.get('x')!;

  test('区切りを全部 ×2: 曲の BPM・区切りの格子・曲の格子がすべて倍になる', () async {
    await container.read(loopItemsProvider.notifier).editTempoKey('x',
        bpm: 150,
        key: null,
        tempo: const [TempoSection(0, 100), TempoSection(60000, 150)],
        keys: const [KeySection(0, 'A#min'), KeySection(156000, 'Bmin')]);
    expect(item().bpm, 150);
    expect(item().beatGrid!.bpm, closeTo(150, 1e-9));
    expect(item().sectionGrids.map((g) => g!.bpm), [100, 150]);
    expect(item().tempoSections.map((s) => s.bpm), [100, 150]);
  });

  test('倍/半分でない値にした区切りは格子を捨てる（ほかの区切りはそのまま）', () async {
    await container.read(loopItemsProvider.notifier).editTempoKey('x',
        bpm: 75,
        key: null,
        tempo: const [TempoSection(0, 66), TempoSection(60000, 75)],
        keys: const [KeySection(0, 'A#min'), KeySection(156000, 'Bmin')]);
    expect(item().sectionGrids[0], isNull);
    expect(item().sectionGrids[1]!.bpm, 75);
    expect(item().beatGrid!.offsetMs, 100);
  });

  test('キーの区切りを直すと、一番長い区切りのキーが曲のキーになる', () async {
    await container.read(loopItemsProvider.notifier).editTempoKey('x',
        bpm: 75,
        key: null,
        tempo: const [TempoSection(0, 50), TempoSection(60000, 75)],
        keys: const [KeySection(0, 'Cmin'), KeySection(156000, 'Dmin')]);
    expect(item().musicalKey, 'Cmin');
    expect(item().keyLabel, 'Cmin → Dmin');
  });

  testWidgets('シート: 区切りごとの欄を出し、×2 は全部に効いて保存できる', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: TempoKeySheet(item: item(), onReanalyze: () {})),
      ),
    ));
    expect(find.text('テンポの区切り'), findsOneWidget);
    expect(find.text('キーの区切り'), findsOneWidget);
    expect(find.text('メイン'), findsOneWidget);
    await tester.tap(find.text('×2'));
    await tester.pump();
    expect(find.text('100'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(item().bpm, 150);
  });

  test('倍/半分でない値に手で直しても「未解析」に戻らない（開くたびに解析し直して上書きしない）',
      () async {
    final x = item()
      ..analyzedAt = 1
      ..leadingSilenceMs = 0
      ..analysisVersion = LoopItem.currentAnalysisVersion;
    await AppBoxes.loopItems.put('x', x);
    expect(AudioAnalysisService.needsAnalysis(item()), isFalse);
    await container
        .read(loopItemsProvider.notifier)
        .saveAnalysis('x', bpm: 80, musicalKey: 'A#min', markAnalyzed: false);
    expect(item().tempoSections, hasLength(2));
    expect(item().sectionGridData, isNotNull);
    expect(item().sectionGrids, [null, null]);
    expect(AudioAnalysisService.needsAnalysis(item()), isFalse);
  });
}
