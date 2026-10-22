import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/audio/bpm_key_detector.dart';
import '../core/audio/silence_detector.dart';
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

  /// ネイティブ側が PCM をここで打ち切る（MainActivity.kt の ANALYSIS_MAX_SECONDS と一致）。
  /// これに達した PCM は曲末まで届いていないので、曲末の無音は求めない
  static const maxAnalysisSeconds = 480;

  /// これより長い曲（ミックス音源・配信の録画など）は解析しない。
  /// 1 曲として BPM / キーを出しても意味がなく、音声の取得にも時間がかかる
  static const maxAnalyzableMinutes = 10;

  /// 長すぎて解析しない曲か。長さが不明なら false（解析の前に [ensureDuration] で埋める）
  static bool isTooLong(LoopItem item) =>
      item.durationMs != null &&
      item.durationMs! > maxAnalyzableMinutes * 60 * 1000;

  /// 解析が必要か。未解析のほか、形式の版が古い解析結果（無音情報や拍の格子の無い
  /// 旧バージョンのもの。手動補正しただけの曲は版が据え置きなので対象のまま）も対象。
  /// v1.86.2 までは解析の時刻で判定していたが、境目の後に旧いアプリで解析した曲が
  /// 「解析済み」になって拍の格子が付かなかった。長すぎる曲は対象外
  static bool needsAnalysis(LoopItem item) =>
      !isTooLong(item) &&
      (item.analyzedAt == null ||
          item.leadingSilenceMs == null ||
          (item.analysisVersion ?? 0) < LoopItem.currentAnalysisVersion);

  /// 解析が必要なアイテムなら、PCM を受け取って解析→保存するコールバックを返す。
  /// 解析済み・解析中・長すぎる曲なら null（波形生成側は PCM を取り出さない）。
  /// [duration] はプレイヤーが知っている曲の長さ（まだ保存されていないことがあるので別に渡す）
  static PcmCallback? sinkFor(LoopItemsNotifier items, LoopItem item,
      {Duration? duration}) {
    if (duration != null &&
        duration > const Duration(minutes: maxAnalyzableMinutes)) {
      return null;
    }
    if (!needsAnalysis(item) || _inFlight.contains(item.id)) return null;
    return (pcm, sampleRate) => run(items, item.id, pcm, sampleRate);
  }

  /// 曲の長さが不明な YouTube の曲なら問い合わせて保存する（ローカルは再生時に埋まる）。
  /// 戻り値は保存後のアイテム（長さが分かったら [isTooLong] で判定できる）
  static Future<void> ensureDuration(
    LoopItemsNotifier items,
    YouTubeService ytService,
    LoopItem item,
  ) async {
    if (item.durationMs != null || !item.isYouTube || item.videoId == null) {
      return;
    }
    final d = await ytService.getDuration(item.videoId!);
    if (d != null) await items.saveDuration(item.id, d.inMilliseconds);
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
      final truncated = pcm.length >= maxAnalysisSeconds * sampleRate;
      final (result, silence) = await Isolate.run(() => (
            BpmKeyDetector.analyze(pcm, sampleRate),
            SilenceDetector.detect(pcm, sampleRate, truncated: truncated),
          ));
      await items.saveAnalysis(itemId,
          bpm: result.bpm,
          musicalKey: result.key,
          silence: silence,
          beatGrid: result.beatGrid);
      debugPrint('[AudioAnalysis] $itemId: ${result.bpm} BPM ${result.key} '
          '拍 ${result.beatGrid}');
      return result;
    } catch (e) {
      debugPrint('[AudioAnalysis] 失敗: $e');
      return null;
    } finally {
      _inFlight.remove(itemId);
    }
  }

  /// 音声の取得から解析・保存までを単独で行う（再生していないときの手動解析用）。
  /// PCM が取れない形式（MP4 フォールバック経路）や取得失敗、長すぎる曲は null
  /// （長すぎるかは呼び出し側が [isTooLong] で見分けられる）
  static Future<AudioAnalysisResult?> analyzeItem(
    LoopItemsNotifier items,
    YouTubeService ytService,
    LoopItem item,
  ) async {
    if (_inFlight.contains(item.id)) return null;
    await ensureDuration(items, ytService, item);
    if (isTooLong(item)) return null;
    final completer = Completer<AudioAnalysisResult?>();
    final useLocal = item.isLocal || item.isCached;
    final source = VideoSource(
      type: useLocal ? VideoSourceType.local : VideoSourceType.youtube,
      uri: useLocal ? (item.cachedVideoPath ?? item.uri) : item.uri,
      title: item.title,
      videoId: item.videoId,
    );
    try {
      // 波形も保存する。渡し忘れていて、まとめて解析した曲でも再生時に
      // 音声を取り直して「波形を読込中」になっていた
      await WaveformService().generateForVideoSource(
        source,
        ytService,
        onPcm: (pcm, sampleRate) {
          completer.complete(run(items, item.id, pcm, sampleRate));
        },
        cacheKey: item.id,
      );
    } catch (e) {
      debugPrint('[AudioAnalysis] 音声取得失敗: $e');
    }
    if (!completer.isCompleted) completer.complete(null);
    return completer.future;
  }

  /// 解析が必要なアイテムだけを抜き出す（プレイリストの「まとめて解析」用）
  static List<LoopItem> unanalyzed(Iterable<LoopItem> items) =>
      [for (final i in items) if (needsAnalysis(i)) i];
}
