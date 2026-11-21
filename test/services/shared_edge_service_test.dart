import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:u2b_loop_app/core/audio/shared_edges.dart';
import 'package:u2b_loop_app/core/audio/wave_bands.dart';
import 'package:u2b_loop_app/core/storage/app_boxes.dart';
import 'package:u2b_loop_app/models/loop_item.dart';
import 'package:u2b_loop_app/providers/data_provider.dart';
import 'package:u2b_loop_app/services/audio_analysis_service.dart';
import 'package:u2b_loop_app/services/shared_edge_service.dart';
import 'package:u2b_loop_app/services/waveform_cache.dart';

const _perSec = 20;

Uint8List _noise(int seed, int n) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => 40 + r.nextInt(180)));
}

/// 本体 120 秒 + （あれば）共通の 15 秒
WaveBands _bands(int seed, {bool card = true}) {
  Uint8List band(int b) => Uint8List.fromList([
        ..._noise(seed * 10 + b, 120 * _perSec),
        if (card) ..._noise(990 + b, 15 * _perSec),
      ]);
  return WaveBands(stepMs: 50, low: band(0), mid: band(1), high: band(2));
}

/// 保存済みの帯域の波形から、実際のファイルと isolate を通して端を見つける
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late ProviderContainer container;

  setUpAll(() async {
    Hive.init(null);
    Hive.registerAdapter(LoopItemAdapter());
    await Hive.openBox(AppBoxes.settingsName, bytes: Uint8List(0));
    await Hive.openBox<LoopItem>(AppBoxes.loopItemsName, bytes: Uint8List(0));
  });
  tearDownAll(() => Hive.close());

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shared_edges');
    messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
    SharedEdgeService.debugReset();
    await AppBoxes.settings.clear();
    await AppBoxes.loopItems.clear();
    container = ProviderContainer();
  });
  tearDown(() {
    container.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    dir.deleteSync(recursive: true);
  });

  Future<void> addSong(String id, int seed, {bool card = true}) async {
    await AppBoxes.loopItems.put(
      id,
      LoopItem(
        id: id,
        title: id,
        uri: 'u',
        sourceType: SourceTypes.local,
        analyzedAt: 1,
        analysisVersion: LoopItem.currentAnalysisVersion,
        leadingSilenceMs: 0,
        trailingSilenceMs: 0,
        mixOutMs: 100000,
      ),
    );
    final path = (await WaveformCache.bandsPaths([id]))[id]!;
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(_bands(seed, card: card).encode());
  }

  LoopItem item(String id) => AppBoxes.loopItems.get(id)!;
  LoopItemsNotifier notifier() {
    // 箱に足した曲を読み直すため作り直す
    container.dispose();
    container = ProviderContainer();
    return container.read(loopItemsProvider.notifier);
  }

  group('scanLibrary', () {
    test('解析済みの曲を見比べて、共通の終わりを残す。カードの無い曲は触らない', () async {
      await addSong('a', 1);
      await addSong('b', 2);
      await addSong('c', 3);
      await addSong('plain', 4, card: false);
      await SharedEdgeService.scanLibrary(notifier());
      for (final id in ['a', 'b', 'c']) {
        expect(item(id).sharedTailMs, 15000, reason: id);
        expect(AudioAnalysisService.needsAnalysis(item(id)), isTrue, reason: id);
      }
      expect(item('plain').sharedTailMs, isNull);
      expect(AudioAnalysisService.needsAnalysis(item('plain')), isFalse);
      expect(AppBoxes.settings.get(SettingsKeys.sharedEdgesScanned), isTrue);
    });

    test('一度見比べたら、次の起動では見ない', () async {
      await AppBoxes.settings.put(SettingsKeys.sharedEdgesScanned, true);
      await addSong('a', 1);
      await addSong('b', 2);
      await addSong('c', 3);
      await SharedEdgeService.scanLibrary(notifier());
      expect(item('a').sharedTailMs, isNull);
    });

    test('曲が少なくても完了の印は付く', () async {
      await addSong('a', 1);
      await SharedEdgeService.scanLibrary(notifier());
      expect(AppBoxes.settings.get(SettingsKeys.sharedEdgesScanned), isTrue);
    });
  });

  group('update', () {
    test('3 曲目を解析すると、その曲の端を返し、前からある 2 曲にも残す', () async {
      await addSong('a', 1);
      await addSong('b', 2);
      await addSong('c', 3);
      final edge = await SharedEdgeService.update(notifier(), 'c', Int16List(0), 11025);
      expect(edge.tailMs, 15000);
      expect(item('a').sharedTailMs, 15000);
      expect(item('b').sharedTailMs, 15000);
      expect(item('c').sharedTailMs, 15000);
    });

    test('帯域の波形がまだ無ければ PCM から求める（短すぎれば今の値のまま）', () async {
      await AppBoxes.loopItems.put(
          'x', LoopItem(id: 'x', title: 'x', uri: 'u', sourceType: SourceTypes.local));
      final edge = await SharedEdgeService.update(notifier(), 'x', Int16List(10), 11025);
      expect(edge, SharedEdge.none);
    });

    test('カードの無い曲は何も変えない', () async {
      await addSong('a', 1);
      await addSong('b', 2);
      await addSong('plain', 4, card: false);
      final edge = await SharedEdgeService.update(notifier(), 'plain', Int16List(0), 11025);
      expect(edge, SharedEdge.none);
      expect(item('plain').mixOutMs, 100000);
    });
  });
}
