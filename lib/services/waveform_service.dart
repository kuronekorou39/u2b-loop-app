import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/native_channels.dart';
import '../models/loop_item.dart';
import '../models/video_source.dart';
import 'audio_analysis_service.dart';
import 'playback/hq_audio.dart';
import 'waveform_cache.dart';
import 'youtube_service.dart';

/// テンポ/キー解析用に間引いたモノラル PCM を受け取る。
/// 波形生成のデコードに相乗りするので、呼び出し側のデコードコストは増えない。
typedef PcmCallback = void Function(Int16List pcm, int sampleRate);

class WaveformService {

  /// 前回の抽出をキャンセル（ネイティブ側の MediaExtractor を解放）
  Future<void> cancel() async {
    try {
      await NativeChannels.waveform.invokeMethod('cancelExtraction');
    } catch (_) {}
  }

  /// Android MediaExtractorで音声サンプルサイズを取得 → 波形データ化
  /// ローカルファイルパスを渡す（YouTube URL は generateFromAudioUrl を使うこと）
  /// [onPcm] を渡すと解析用 PCM も一緒に取り出して渡す（MediaCodec 経路のみ）
  Future<List<double>?> generateFromUrl(
    String url,
    int targetSamples, {
    PcmCallback? onPcm,
  }) async {
    final withPcm = onPcm != null;
    final raw = await NativeChannels.waveform.invokeMethod<dynamic>(
      'extractAmplitudes',
      {'url': url, 'withPcm': withPcm},
    );

    List<dynamic>? result;
    if (raw is Map) {
      result = raw['amplitudes'] as List<dynamic>?;
      final pcm = raw['pcm'];
      final sampleRate = raw['sampleRate'];
      if (withPcm && pcm is Uint8List && pcm.isNotEmpty && sampleRate is int) {
        onPcm(_toInt16(pcm), sampleRate);
      }
    } else if (raw is List) {
      result = raw;
    }

    if (result == null || result.isEmpty) {
      return null;
    }

    final amplitudes = result.cast<int>();
    return _downsampleAndNormalize(amplitudes, targetSamples);
  }

  /// ネイティブはリトルエンディアンの16bitで返す。奇数オフセットだと view できないのでコピーする
  static Int16List _toInt16(Uint8List bytes) {
    if (bytes.offsetInBytes.isEven) {
      return Int16List.view(
          bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
    }
    return Int16List.view(Uint8List.fromList(bytes).buffer);
  }

  /// ローカルファイルから波形データを生成
  Future<List<double>?> generateForLocalFile(
    String path,
    int targetSamples, {
    PcmCallback? onPcm,
  }) async {
    // まずMediaCodecデコードで試行
    try {
      final result = await generateFromUrl(path, targetSamples, onPcm: onPcm);
      if (result != null) return result;
    } catch (_) {
      // MediaCodecが失敗したらフォールバックへ
    }

    // フォールバック: MP4 stszパース
    final file = File(path);
    if (!await file.exists()) return null;
    final data = await file.readAsBytes();

    final mp4Result = _extractFromMp4(data, targetSamples);
    if (mp4Result != null) return mp4Result;

    return _extractFromByteEnergy(data, targetSamples);
  }

  // --- MP4 stsz パーサー (フォールバック用) ---

  List<double>? _extractFromMp4(Uint8List data, int targetSamples) {
    final stszOffsets = <int>[];
    _findAtomsByType(data, 0, data.length, 'stsz', stszOffsets);

    for (final offset in stszOffsets) {
      final result = _parseStszAtom(data, offset, targetSamples);
      if (result != null) return result;
    }
    return null;
  }

  List<double>? _parseStszAtom(
    Uint8List data,
    int atomOffset,
    int targetSamples,
  ) {
    if (atomOffset + 20 > data.length) return null;
    final bd = ByteData.sublistView(data);

    final sampleSize = bd.getUint32(atomOffset + 12);
    final sampleCount = bd.getUint32(atomOffset + 16);

    if (sampleSize != 0) return null;
    if (sampleCount == 0 || sampleCount > 10000000) return null;
    if (atomOffset + 20 + sampleCount * 4 > data.length) return null;

    final sizes = List<int>.generate(
      sampleCount,
      (i) => bd.getUint32(atomOffset + 20 + i * 4),
    );

    return _downsampleAndNormalize(sizes, targetSamples);
  }

  void _findAtomsByType(
    Uint8List data,
    int start,
    int end,
    String target,
    List<int> results,
  ) {
    var offset = start;
    if (end > data.length) end = data.length;
    final bd = ByteData.sublistView(data);

    while (offset + 8 <= end) {
      final size = bd.getUint32(offset);
      if (size < 8 || offset + size > end) break;

      final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));

      if (type == target) {
        results.add(offset);
      }

      const containers = {
        'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'udta',
      };
      if (containers.contains(type)) {
        _findAtomsByType(data, offset + 8, offset + size, target, results);
      }

      offset += size;
    }
  }

  // --- バイトエネルギー解析 ---

  List<double> _extractFromByteEnergy(Uint8List data, int targetSamples) {
    if (data.length < targetSamples * 2) {
      return List.filled(targetSamples, 0.5);
    }

    final chunkSize = data.length ~/ targetSamples;
    final peaks = List<double>.generate(targetSamples, (i) {
      final start = i * chunkSize;
      final end = min(start + chunkSize, data.length - 1);
      var diffSum = 0.0;
      var count = 0;
      for (var j = start; j < end; j++) {
        diffSum += (data[j + 1] - data[j]).abs();
        count++;
      }
      return count > 0 ? diffSum / count : 0;
    });

    final maxPeak = peaks.reduce(max);
    if (maxPeak > 0) {
      for (var i = 0; i < peaks.length; i++) {
        peaks[i] = (peaks[i] / maxPeak).clamp(0.05, 1.0);
      }
    }

    final smoothed = List<double>.filled(targetSamples, 0);
    for (var i = 0; i < targetSamples; i++) {
      final prev = i > 0 ? peaks[i - 1] : peaks[i];
      final next = i < targetSamples - 1 ? peaks[i + 1] : peaks[i];
      smoothed[i] = (prev + peaks[i] + next) / 3;
    }
    return smoothed;
  }

  // --- 音声DL + 波形生成（PlayerScreen/EditorScreen共通） ---

  static const _tempPrefix = 'u2b_waveform_';

  /// 画面が異常終了して消し損ねた一時ファイルを掃除する。
  /// 進行中のDL（最長30秒）を巻き込まないよう1時間以上前のものだけ消す。
  Future<void> _sweepStaleTempFiles(Directory tempDir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in tempDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(_tempPrefix) || !name.endsWith('.tmp')) continue;
        try {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 音声ストリームを一時ファイルにダウンロードし、パスを返す。
  /// タイムアウトしても100KB超ならパスを返す。失敗時はnull。
  Future<String?> downloadAudioToTemp(
    Stream<List<int>> audioStream, {
    String? fileName,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      // 固定名にすると、素早く曲を切り替えたときに並行DLが同じファイルへ
      // 書き込み合って壊れた音声になる。指定が無ければ毎回一意な名前にする。
      final name = fileName ??
          '$_tempPrefix${DateTime.now().microsecondsSinceEpoch}.tmp';
      await _sweepStaleTempFiles(tempDir);
      final tempFile = File('${tempDir.path}/$name');
      final sink = tempFile.openWrite();
      var bytes = 0;
      final sub = audioStream.listen((chunk) {
        sink.add(chunk);
        bytes += chunk.length;
      });
      try {
        await sub.asFuture<void>().timeout(timeout);
      } on TimeoutException {
        // タイムアウトしてもDL済みバイト数で判定
      } finally {
        try { await sub.cancel().timeout(const Duration(seconds: 2)); } catch (_) {}
        try { await sink.flush().timeout(const Duration(seconds: 2)); } catch (_) {}
        try { await sink.close().timeout(const Duration(seconds: 2)); } catch (_) {}
      }
      if (bytes > 100000) return tempFile.path;
      try { await tempFile.delete(); } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  /// キャッシュ済み音声ファイルから波形を生成し、ファイルを削除して返す。
  /// 波形用の音声を先読みしてローカルに落とす。パスを返す（失敗時null）。
  /// 取得済みのマニフェストを使い回すので、再生開始直後に呼ぶと安上がり。
  ///
  /// 高音質再生が有効なら再生用に落とす音声専用ストリーム（HqAudio）をそのまま使う
  /// （映像込みの一体型より小さく、再生側と 1 回の DL で済む）。
  /// その音声は HqAudio が管理するので使い終わっても消さない（[generateFromCachedAudio]）
  Future<String?> prefetchAudio(
    StreamManifest manifest,
    YouTubeService ytService, {
    required String videoId,
  }) async {
    if (HqAudio.enabled) {
      HqAudio.log('波形: 取得を依頼');
      final hq = await HqAudio.fetch(videoId, manifest: manifest);
      if (hq != null) return hq;
    }
    final muxed = manifest.muxed.sortByVideoQuality();
    if (muxed.isEmpty) return null;
    return downloadAudioToTemp(
        ytService.yt.videos.streamsClient.get(muxed.first));
  }

  /// 動画ソースから波形を生成する（ローカル/YouTube共通の入口）。
  ///
  /// YouTubeは音声を一時ファイルに落としてから抽出する。
  /// MediaExtractor にリモートURLを直接渡すとプレイヤーとCDN接続が競合するため。
  /// [cachedAudioPath] を渡すとDLを省略する（[prefetchAudio] の結果を使う）。
  /// 使い終わった一時ファイルは内部で削除する。
  ///
  /// [cacheKey]（アイテムID）を渡すと [WaveformCache] を使う。
  /// ただし [onPcm] がある＝解析が必要なときは、PCM を取るために生成し直す。
  Future<List<double>?> generateForVideoSource(
    VideoSource source,
    YouTubeService ytService, {
    String? cachedAudioPath,
    int targetSamples = 4000,
    PcmCallback? onPcm,
    String? cacheKey,
  }) async {
    if (cacheKey != null && onPcm == null && cachedAudioPath == null) {
      final cached = await WaveformCache.load(cacheKey);
      if (cached != null && cached.isNotEmpty) return cached;
    }
    final waveform = await _generateForVideoSource(source, ytService,
        cachedAudioPath: cachedAudioPath,
        targetSamples: targetSamples,
        onPcm: onPcm);
    if (cacheKey != null && waveform != null && waveform.isNotEmpty) {
      await WaveformCache.save(cacheKey, waveform);
    }
    return waveform;
  }

  Future<List<double>?> _generateForVideoSource(
    VideoSource source,
    YouTubeService ytService, {
    String? cachedAudioPath,
    required int targetSamples,
    PcmCallback? onPcm,
  }) async {
    if (source.type == VideoSourceType.local) {
      return generateForLocalFile(source.uri, targetSamples, onPcm: onPcm);
    }
    final videoId = source.videoId;
    if (videoId == null) return null;

    var path = cachedAudioPath;
    if (path == null) {
      final manifest = await ytService
          .getManifestWithFallback(videoId)
          .timeout(const Duration(seconds: 30));
      path = await prefetchAudio(manifest, ytService, videoId: videoId);
      if (path == null) return null;
    }
    return generateFromCachedAudio(path, targetSamples: targetSamples, onPcm: onPcm);
  }

  /// 波形がキャッシュ済みで、解析も不要なら true（音声 DL を省ける）
  static Future<bool> canSkipAudioFetch(LoopItem item) async =>
      !AudioAnalysisService.needsAnalysis(item) &&
      await WaveformCache.exists(item.id);

  Future<List<double>?> generateFromCachedAudio(
    String audioPath, {
    int targetSamples = 4000,
    PcmCallback? onPcm,
  }) async {
    try {
      return await generateForLocalFile(audioPath, targetSamples, onPcm: onPcm);
    } finally {
      // 再生にも使う高音質の音声は HqAudio が寿命を持つので消さない
      if (!HqAudio.isManagedPath(audioPath)) {
        try { await File(audioPath).delete(); } catch (_) {}
      }
    }
  }

  // --- 共通ユーティリティ ---

  List<double> _downsampleAndNormalize(List<int> sizes, int targetSamples) {
    final n = sizes.length;
    if (n == 0) return List.filled(targetSamples, 0);
    final samplesPerBucket = n / targetSamples;
    final peaks = List<double>.generate(targetSamples, (i) {
      final start = (i * samplesPerBucket).floor();
      final end = min(((i + 1) * samplesPerBucket).floor(), n);
      var maxVal = 0;
      for (var j = start; j < end; j++) {
        if (sizes[j] > maxVal) maxVal = sizes[j];
      }
      return maxVal.toDouble();
    });

    final maxPeak = peaks.reduce(max);
    if (maxPeak > 0) {
      for (var i = 0; i < peaks.length; i++) {
        peaks[i] = peaks[i] / maxPeak;
      }
    }
    return peaks;
  }
}
