import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/music_span_detector.dart';
import 'package:u2b_loop_app/core/audio/silence_detector.dart';
import 'package:u2b_loop_app/core/audio/tempo_sections.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';

/// 曲の範囲（v5）の保存: 飛ばす長さ・曲ではない判定、v4 の解析結果の据え置き
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
    // v4 で解析済み、手で 120 → 60 に直した曲
    await AppBoxes.loopItems.put(
      'x',
      LoopItem(
        id: 'x',
        title: 't',
        uri: 'u',
        sourceType: 'local',
        bpm: 60,
        musicalKey: 'Cmaj',
        beatBpm: 60,
        beatOffsetMs: 100,
        beatConfidence: 0.8,
        analyzedAt: 1,
        analysisVersion: 4,
        leadingSilenceMs: 500,
        trailingSilenceMs: 800,
        mixInMs: 20000,
        mixOutMs: 180000,
        headDb: -10,
      ),
    );
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  LoopItem item() => AppBoxes.loopItems.get('x')!;
  Future<void> save(MusicSpanInfo span) => container.read(loopItemsProvider.notifier).saveAnalysis(
        'x',
        bpm: 121,
        musicalKey: 'Gmin',
        silence: const SilenceInfo(leadingMs: 500, trailingMs: 800),
        beatGrid: const BeatGrid(bpm: 121, offsetMs: 300, confidence: 0.7),
        span: span,
      );

  test('v4 の曲で新たに飛ばす部分が無ければ、手で直した BPM・格子・ミックス点はそのまま', () async {
    await save(const MusicSpanInfo(headMs: 0, tailMs: 0, notMusic: false));
    expect(item().bpm, 60);
    expect(item().musicalKey, 'Gmin', reason: 'キーは検出を直したので必ず置き換える');
    expect(item().beatGrid!.bpm, 60);
    expect(item().mixInMs, 20000);
    expect(item().analysisVersion, LoopItem.currentAnalysisVersion);
  });

  test('頭のトークを飛ばすようになったら解析し直した値にし、ミックス点も取り直す', () async {
    await save(const MusicSpanInfo(headMs: 30000, tailMs: 0, notMusic: false));
    expect(item().bpm, 121);
    expect(item().beatGrid!.offsetMs, 300);
    expect(item().introSkipMs, 30000);
    expect(item().outroSkipMs, 800);
    expect(item().mixInMs, isNull);
    expect(item().headDb, isNull);
  });

  test('曲ではないなら BPM は空で、表示は「BPM —」', () async {
    await container.read(loopItemsProvider.notifier).saveAnalysis('x',
        bpm: null,
        musicalKey: null,
        beatGrid: null,
        span: const MusicSpanInfo(headMs: 0, tailMs: null, notMusic: true));
    expect(item().bpm, isNull);
    expect(item().notMusic, isTrue);
    expect(item().bpmLabel, 'BPM —');
    expect(item().beatGrid, isNull);
  });

  test('飛ばす長さは無音と曲でない部分の長い方', () {
    final i = LoopItem(id: 'a', title: 't', uri: 'u', sourceType: 'local');
    expect(i.introSkipMs, 0);
    expect(i.outroSkipMs, isNull);
    i
      ..leadingSilenceMs = 2000
      ..musicHeadMs = 1000
      ..musicTailMs = 15000
      ..trailingSilenceMs = 3000;
    expect(i.introSkipMs, 2000);
    expect(i.outroSkipMs, 15000);
  });
  test('テンポが変わる曲は v4 でも解析し直した値にし、区切りを残す', () async {
    await container.read(loopItemsProvider.notifier).saveAnalysis('x',
        bpm: 150,
        musicalKey: 'Gmin',
        silence: const SilenceInfo(leadingMs: 500, trailingMs: 800),
        beatGrid: const BeatGrid(bpm: 150, offsetMs: 300, confidence: 0.7),
        span: const MusicSpanInfo(headMs: 0, tailMs: 0, notMusic: false),
        sections: const [TempoSection(0, 100), TempoSection(60000, 150)]);
    expect(item().bpm, 150);
    expect(item().tempoSections, hasLength(2));
    expect(item().bpmLabel, '150 BPM（100〜150）');
  });

  test('手で BPM を ×2 にすると区切りも ×2', () async {
    final notifier = container.read(loopItemsProvider.notifier);
    await notifier.saveAnalysis('x',
        bpm: 75,
        musicalKey: null,
        span: const MusicSpanInfo(headMs: 0, tailMs: 0, notMusic: false),
        sections: const [TempoSection(0, 50), TempoSection(60000, 75)]);
    await notifier.saveAnalysis('x', bpm: 150, musicalKey: null, markAnalyzed: false);
    expect(item().tempoSections.map((s) => s.bpm), [100, 150]);
  });
}
