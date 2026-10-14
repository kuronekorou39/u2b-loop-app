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

  /// 拍の格子を解析に入れた時刻（v1.86.0 のビルド）。これより前の解析結果は拍合わせに
  /// 使えないので解析し直す（この後に手動補正しただけの曲は analyzedAt が据え置きなので対象のまま）。
  /// v1.86.0 ではこれを翌日にしていたため、その日のうちは解析したばかりの曲も毎回対象になっていた。
  /// タイムゾーンで境目がずれないよう UTC で書く（2026-10-14 15:00 JST）
  static final beatGridSince =
      DateTime.utc(2026, 10, 14, 6).millisecondsSinceEpoch;

  /// これより長い曲（ミックス音源・配信の録画など）は解析しない。
  /// 1 曲として BPM / キーを出しても意味がなく、音声の取得にも時間がかかる
  static const maxAnalyzableMinutes = 10;

  /// 長すぎて解析しない曲か。長さが不明なら false（解析の前に [ensureDuration] で埋める）
  static bool isTooLong(LoopItem item) =>
      item.durationMs != null &&
      item.durationMs! > maxAnalyzableMinutes * 60 * 1000;

  /// 解析が必要か。未解析のほか、無音情報や拍の格子の無い旧バージョンの解析結果も対象。
  /// 長すぎる曲は対象外
  static bool needsAnalysis(LoopItem item) =>
      !isTooLong(item) &&
      (item.analyzedAt == null ||
          item.leadingSilenceMs == null ||
          item.analyzedAt! < beatGridSince);

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

  /// 解析が必要なアイテムだけを抜き出す（プレイリストの「まとめて解析」用）
  static List<LoopItem> unanalyzed(Iterable<LoopItem> items) =>
      [for (final i in items) if (needsAnalysis(i)) i];

  /// [targets] を1件ずつ順に解析する。
  /// 並列にすると音声のダウンロードが詰まるので直列。
  /// [onProgress] は各曲の開始時に (完了数, 総数, これから解析する曲) で呼ぶ。
  /// [shouldStop] が true を返したら、進行中の1件が終わった時点で打ち切る。
  /// 戻り値は解析できた件数と、長すぎて省いた件数
  static Future<({int done, int skipped})> analyzeAll(
    LoopItemsNotifier items,
    YouTubeService ytService,
    List<LoopItem> targets, {
    void Function(int done, int total, LoopItem current)? onProgress,
    bool Function()? shouldStop,
  }) async {
    var succeeded = 0, skipped = 0;
    for (var i = 0; i < targets.length; i++) {
      if (shouldStop?.call() ?? false) break;
      onProgress?.call(i, targets.length, targets[i]);
      final result = await analyzeItem(items, ytService, targets[i]);
      if (result != null) {
        succeeded++;
      } else if (isTooLong(targets[i])) {
        skipped++;
      }
    }
    return (done: succeeded, skipped: skipped);
  }
}
