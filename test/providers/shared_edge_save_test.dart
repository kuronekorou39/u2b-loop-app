import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/audio/beat_grid.dart';
import 'package:u2b_loop_app/core/audio/music_span_detector.dart';
import 'package:u2b_loop_app/core/audio/shared_edges.dart';
import 'package:u2b_loop_app/core/audio/silence_detector.dart';
import 'package:u2b_loop_app/core/audio/verse_ending.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/services/audio_analysis_service.dart';

/// 共通の端（エンドカード）の保存と、1 番の終わり方の保存
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  const autoGrid = BeatGrid(bpm: 115, offsetMs: 100, confidence: 0.8);
  const span = MusicSpanInfo(headMs: 0, tailMs: 0, notMusic: false, noSteadyBeat: false);

  late ProviderContainer container;
  setUp(() async {
    await AppBoxes.loopItems.clear();
    await AppBoxes.loopItems.put(
      'x',
      LoopItem(
        id: 'x',
        title: 't',
        uri: 'u',
        sourceType: 'local',
        bpm: 115,
        musicalKey: 'Cmaj',
        beatBpm: autoGrid.bpm,
        beatOffsetMs: autoGrid.offsetMs,
        beatConfidence: autoGrid.confidence,
        analyzedAt: 1,
        analysisVersion: LoopItem.currentAnalysisVersion,
        leadingSilenceMs: 0,
        trailingSilenceMs: 500,
        mixInMs: 20000,
        mixOutMs: 170000,
        headDb: -10,
        tailDb: -12,
        durationMs: 200000,
      ),
    );
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  LoopItem item() => AppBoxes.loopItems.get('x')!;
  LoopItemsNotifier notifier() => container.read(loopItemsProvider.notifier);

  group('saveSharedEdges', () {
    test('飛ばす範囲に入り、ミックス点は取り直し、次の再生で解析し直す', () async {
      expect(AudioAnalysisService.needsAnalysis(item()), isFalse);
      await notifier().saveSharedEdges({'x': const SharedEdge(tailMs: 18000)});
      expect(item().sharedTailMs, 18000);
      expect(item().outroSkipMs, 18000);
      expect(item().mixInMs, isNull);
      expect(item().mixOutMs, isNull);
      expect(item().headDb, isNull);
      expect(AudioAnalysisService.needsAnalysis(item()), isTrue);
    });

    test('同じ値なら何も変えない', () async {
      await notifier().saveSharedEdges({'x': SharedEdge.none});
      expect(item().mixInMs, 20000);
      expect(AudioAnalysisService.needsAnalysis(item()), isFalse);
    });

    test('未解析の曲に解析の版を付けない', () async {
      item().analysisVersion = null;
      await notifier().saveSharedEdges({'x': const SharedEdge(tailMs: 18000)});
      expect(item().analysisVersion, isNull);
    });

    test('無い曲は無視する', () async {
      await notifier().saveSharedEdges({'nothing': const SharedEdge(tailMs: 18000)});
      expect(AppBoxes.loopItems.length, 1);
    });
  });

  group('端を除いて解析し直す', () {
    const fixed = BeatGrid(bpm: 140, offsetMs: 50, confidence: 0.9);
    const newBase = BeatGrid(bpm: 139, offsetMs: 70, confidence: 0.9);

    Future<void> analyze({BeatGrid? raw}) => notifier().saveAnalysis(
          'x',
          bpm: 140,
          musicalKey: 'Gmin',
          silence: const SilenceInfo(leadingMs: 0, trailingMs: 18000),
          beatGrid: fixed,
          baseGrid: newBase,
          rawGrid: raw,
          span: span,
        );

    test('保存済みの格子が端を除く前の自動の値なら、新しい解析に置き換える', () async {
      await notifier().saveSharedEdges({'x': const SharedEdge(tailMs: 18000)});
      await analyze(raw: autoGrid);
      expect(item().bpm, 140);
      expect(item().beatBpm, fixed.bpm);
      expect(item().analysisVersion, LoopItem.currentAnalysisVersion);
      expect(AudioAnalysisService.needsAnalysis(item()), isFalse);
    });

    test('解析の間に端が変わったら、次の再生でやり直す', () async {
      await notifier().saveSharedEdges({'x': const SharedEdge(tailMs: 18000)});
      await notifier().saveAnalysis(
        'x',
        bpm: 140,
        musicalKey: 'Gmin',
        silence: const SilenceInfo(leadingMs: 0, trailingMs: 500),
        beatGrid: fixed,
        baseGrid: newBase,
        usedEdge: SharedEdge.none,
        span: span,
      );
      expect(AudioAnalysisService.needsAnalysis(item()), isTrue);
    });

    test('手で直した格子は残す', () async {
      item()
        ..beatBpm = 118
        ..beatOffsetMs = 33
        ..bpm = 118;
      await notifier().saveSharedEdges({'x': const SharedEdge(tailMs: 18000)});
      await analyze(raw: autoGrid);
      expect(item().bpm, 118);
      expect(item().beatBpm, 118);
      expect(item().beatOffsetMs, 33);
    });
  });

  group('saveVerseEnding', () {
    test('選んだ終わり方を残し、重ねるに戻すと消す', () async {
      expect(item().verseEnding, VerseEnding.overlap);
      await notifier().saveVerseEnding('x', VerseEnding.echo);
      expect(item().firstVerseEnding, 'echo');
      expect(item().verseEnding, VerseEnding.echo);
      await notifier().saveVerseEnding('x', VerseEnding.overlap);
      expect(item().firstVerseEnding, isNull);
    });

    test('一覧の並びが変わらない（updatedAt を触らない）', () async {
      final before = item().updatedAt;
      await notifier().saveVerseEnding('x', VerseEnding.reverb);
      expect(item().updatedAt, before);
    });
  });
}
