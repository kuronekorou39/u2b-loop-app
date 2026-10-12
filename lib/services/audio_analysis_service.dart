import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/audio/bpm_key_detector.dart';
import '../models/loop_item.dart';
import '../models/video_source.dart';
import '../providers/data_provider.dart';
import 'waveform_service.dart';
import 'youtube_service.dart';

/// テンポ/キー解析の入口。
///
/// 通常は波形生成のデコードに相乗りする（[sinkFor]）。
/// 詳細画面の「解析」ボタンのように単独で動かすときは [analyzeItem]。
class AudioAnalysisService {
  AudioAnalysisService._();

  /// 同じアイテムの解析が重ならないように（再生とプリロードが同時に走ることがある）
  static final _inFlight = <String>{};

  /// 未解析のアイテムなら、PCM を受け取って解析→保存するコールバックを返す。
  /// 解析済み・解析中なら null（波形生成側は PCM を取り出さない）
  static PcmCallback? sinkFor(LoopItemsNotifier items, LoopItem item) {
    if (item.analyzedAt != null || _inFlight.contains(item.id)) return null;
    return (pcm, sampleRate) => run(items, item.id, pcm, sampleRate);
  }

  /// isolate で解析して保存する。失敗時は null
  static Future<AudioAnalysisResult?> run(
    LoopItemsNotifier items,
    String itemId,
    Int16List pcm,
    int sampleRate,
  ) async {
    if (!_inFlight.add(itemId)) return null;
    try {
      final result =
          await Isolate.run(() => BpmKeyDetector.analyze(pcm, sampleRate));
      await items.saveAnalysis(itemId, bpm: result.bpm, musicalKey: result.key);
      return result;
    } catch (e) {
      debugPrint('[AudioAnalysis] 失敗: $e');
      return null;
    } finally {
      _inFlight.remove(itemId);
    }
  }

  /// 音声の取得から解析・保存までを単独で行う（再生していないときの手動解析用）。
  /// PCM が取れない形式（MP4 フォールバック経路）や取得失敗は null
  static Future<AudioAnalysisResult?> analyzeItem(
    LoopItemsNotifier items,
    YouTubeService ytService,
    LoopItem item,
  ) async {
    if (_inFlight.contains(item.id)) return null;
    final completer = Completer<AudioAnalysisResult?>();
    final useLocal = item.isLocal || item.isCached;
    final source = VideoSource(
      type: useLocal ? VideoSourceType.local : VideoSourceType.youtube,
      uri: useLocal ? (item.cachedVideoPath ?? item.uri) : item.uri,
      title: item.title,
      videoId: item.videoId,
    );
    try {
      await WaveformService().generateForVideoSource(
        source,
        ytService,
        onPcm: (pcm, sampleRate) {
          completer.complete(run(items, item.id, pcm, sampleRate));
        },
      );
    } catch (e) {
      debugPrint('[AudioAnalysis] 音声取得失敗: $e');
    }
    if (!completer.isCompleted) completer.complete(null);
    return completer.future;
  }

  /// 未解析のアイテムだけを抜き出す（プレイリストの「まとめて解析」用）
  static List<LoopItem> unanalyzed(Iterable<LoopItem> items) =>
      [for (final i in items) if (i.analyzedAt == null) i];

  /// [targets] を1件ずつ順に解析する。
  /// 並列にすると音声のダウンロードが詰まるので直列。
  /// [onProgress] は各曲の開始時に (完了数, 総数, これから解析する曲) で呼ぶ。
  /// [shouldStop] が true を返したら、進行中の1件が終わった時点で打ち切る。
  /// 戻り値は解析できた件数
  static Future<int> analyzeAll(
    LoopItemsNotifier items,
    YouTubeService ytService,
    List<LoopItem> targets, {
    void Function(int done, int total, LoopItem current)? onProgress,
    bool Function()? shouldStop,
  }) async {
    var succeeded = 0;
    for (var i = 0; i < targets.length; i++) {
      if (shouldStop?.call() ?? false) break;
      onProgress?.call(i, targets.length, targets[i]);
      final result = await analyzeItem(items, ytService, targets[i]);
      if (result != null) succeeded++;
    }
    return succeeded;
  }
}
