import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'export_service.dart';
import 'subtitle_service.dart';
import 'youtube_service.dart';

/// オフラインキャッシュの保存結果。
class OfflineCacheResult {
  final bool success;
  final bool cancelled;
  final String? videoPath;
  final String? subtitlePath;
  final String? resolution;
  final int sizeBytes;
  final String? error;

  const OfflineCacheResult({
    this.success = false,
    this.cancelled = false,
    this.videoPath,
    this.subtitlePath,
    this.resolution,
    this.sizeBytes = 0,
    this.error,
  });
}

/// ダウンロード可能な画質の選択肢。
class CacheQuality {
  /// 表示用ラベル（例: '1080p'）
  final String label;

  /// true なら映像専用+音声専用を別々にDLしてネイティブ結合する（高解像度）
  final bool needsMerge;

  /// muxed もしくは videoOnly ストリームの itag
  final int videoTag;

  /// 結合時に使う audioOnly ストリームの itag
  final int? audioTag;

  /// 合計サイズの概算（バイト）
  final int approxBytes;

  const CacheQuality({
    required this.label,
    required this.needsMerge,
    required this.videoTag,
    this.audioTag,
    this.approxBytes = 0,
  });

  /// 概算サイズの表示（例: '約 120 MB'）
  String get sizeLabel =>
      approxBytes > 0 ? '約 ${(approxBytes / 1024 / 1024).toStringAsFixed(0)} MB' : '';
}

enum _DlState { ok, cancelled, failed }

/// YouTube動画と字幕をアプリ内にダウンロード保存し、オフライン再生を可能にするサービス。
///
/// - muxed（音声+映像一体）を選んだ場合はそのまま保存（結合不要）。
/// - 高解像度（mp4 videoOnly = H.264）を選んだ場合は mp4 audioOnly（AAC）を併せてDLし、
///   ネイティブの MediaMuxer で1つのMP4へ結合する（再エンコードなし、最大1080p想定。
///   VP9/AV1のみの1440p/4Kは MediaMuxer 非対応のため選択肢に出さない）。
/// 保存先は設定 `cache_to_documents` で切替（false=キャッシュ領域[既定], true=documents）。
class CacheService {
  static const _settingsBox = 'settings';
  static const _storageKey = 'cache_to_documents';
  static const _subDirName = 'offline';

  /// 保存先ディレクトリ（設定に応じてキャッシュ領域 or documents）。
  Future<Directory> _cacheDir() async {
    final base = _persistent
        ? await getApplicationDocumentsDirectory()
        : await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/$_subDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  bool get _persistent {
    try {
      return Hive.box(_settingsBox).get(_storageKey, defaultValue: false)
          as bool;
    } catch (_) {
      return false;
    }
  }

  /// ダウンロード可能な画質一覧を返す（解像度の高い順）。
  /// muxed（結合不要）と mp4 videoOnly（結合必要）を統合し、同一ラベルは muxed を優先。
  Future<List<CacheQuality>> qualityOptions(String videoId) async {
    final service = YouTubeService();
    try {
      final manifest = await service.getManifestWithFallback(videoId);
      final byLabel = <String, CacheQuality>{};

      // muxed（結合不要）を優先登録
      for (final m in manifest.muxed) {
        byLabel[m.qualityLabel] = CacheQuality(
          label: m.qualityLabel,
          needsMerge: false,
          videoTag: m.tag,
          approxBytes: m.size.totalBytes,
        );
      }

      // mp4 videoOnly(H.264) + mp4 audioOnly(AAC) で結合可能な高解像度を追加
      final mp4Audios =
          manifest.audioOnly.where((a) => a.container == StreamContainer.mp4);
      if (mp4Audios.isNotEmpty) {
        final bestAudio = mp4Audios.withHighestBitrate();
        // H.264(avc)のみ。AV1/VP9はMediaMuxerのMP4結合が端末により非対応なため除外
        // （YouTubeは通常1080pまでavcを提供）。
        for (final v in manifest.videoOnly.where((v) =>
            v.container == StreamContainer.mp4 &&
            v.videoCodec.startsWith('avc'))) {
          byLabel.putIfAbsent(
            v.qualityLabel,
            () => CacheQuality(
              label: v.qualityLabel,
              needsMerge: true,
              videoTag: v.tag,
              audioTag: bestAudio.tag,
              approxBytes: v.size.totalBytes + bestAudio.size.totalBytes,
            ),
          );
        }
      }

      final list = byLabel.values.toList()
        ..sort((a, b) => _resValue(b.label) - _resValue(a.label));
      return list;
    } finally {
      service.dispose();
    }
  }

  /// [videoId] の動画と字幕(SRT)をダウンロードして保存する。
  ///
  /// [quality] 省略時は最高画質の muxed を使用。[onProgress] は 0.0〜1.0、
  /// [isCancelled] が true を返したら中断。
  Future<OfflineCacheResult> downloadForOffline(
    String id,
    String videoId, {
    CacheQuality? quality,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final service = YouTubeService();
    try {
      final manifest = await service.getManifestWithFallback(videoId);
      final dir = await _cacheDir();
      final videoFile = File('${dir.path}/$id.mp4');
      final String resolution;

      if (quality != null && quality.needsMerge && quality.audioTag != null) {
        // 高解像度: 映像専用+音声専用を別DL → ネイティブ結合
        final vInfo =
            manifest.videoOnly.firstWhere((v) => v.tag == quality.videoTag);
        final aInfo =
            manifest.audioOnly.firstWhere((a) => a.tag == quality.audioTag);
        resolution = quality.label;

        final tmpDir = await getTemporaryDirectory();
        final tmpV = File('${tmpDir.path}/${id}_v.tmp');
        final tmpA = File('${tmpDir.path}/${id}_a.tmp');
        final vBytes = vInfo.size.totalBytes;
        final aBytes = aInfo.size.totalBytes;
        final total = (vBytes + aBytes) > 0 ? (vBytes + aBytes) : 1;

        final okV = await _downloadStream(
          service, vInfo, tmpV, isCancelled,
          (r) => onProgress?.call((r / total).clamp(0.0, 0.98)),
        );
        if (okV != _DlState.ok) {
          await _safeDelete(tmpV);
          return okV == _DlState.cancelled
              ? const OfflineCacheResult(cancelled: true)
              : const OfflineCacheResult(error: '映像のダウンロードに失敗しました');
        }

        final okA = await _downloadStream(
          service, aInfo, tmpA, isCancelled,
          (r) => onProgress?.call(((vBytes + r) / total).clamp(0.0, 0.99)),
        );
        if (okA != _DlState.ok) {
          await _safeDelete(tmpV);
          await _safeDelete(tmpA);
          return okA == _DlState.cancelled
              ? const OfflineCacheResult(cancelled: true)
              : const OfflineCacheResult(error: '音声のダウンロードに失敗しました');
        }

        final muxOk = await ExportService().muxVideoAudio(
          videoPath: tmpV.path,
          audioPath: tmpA.path,
          outputPath: videoFile.path,
        );
        await _safeDelete(tmpV);
        await _safeDelete(tmpA);
        if (!muxOk) {
          await _safeDelete(videoFile);
          return const OfflineCacheResult(error: '映像と音声の結合に失敗しました');
        }
        onProgress?.call(1.0);
      } else {
        // muxed（結合不要、単一DL）
        final muxedList = manifest.muxed.sortByVideoQuality();
        if (muxedList.isEmpty) {
          return const OfflineCacheResult(
              error: '保存可能な音声付きストリームがありません（高解像度のみの動画）');
        }
        final info = quality != null
            ? muxedList.firstWhere((m) => m.tag == quality.videoTag,
                orElse: () => muxedList.last)
            : muxedList.last;
        resolution = info.qualityLabel;
        final total = info.size.totalBytes;

        final ok = await _downloadStream(
          service, info, videoFile, isCancelled,
          (r) {
            if (total > 0) onProgress?.call((r / total).clamp(0.0, 1.0));
          },
        );
        if (ok != _DlState.ok) {
          await _safeDelete(videoFile);
          return ok == _DlState.cancelled
              ? const OfflineCacheResult(cancelled: true)
              : const OfflineCacheResult(error: 'ダウンロードに失敗しました');
        }
      }

      final sizeBytes = await videoFile.length();

      // 字幕（ja優先、無ければen/先頭）をSRTで保存
      String? subtitlePath;
      try {
        final subResult = await SubtitleService.fetchSubtitles(videoId);
        final subs = subResult.subs;
        if (subs != null && subs.isNotEmpty) {
          final srt = SubtitleService.toSrt(subs);
          final subFile = File('${dir.path}/$id.srt');
          await subFile.writeAsString(srt);
          subtitlePath = subFile.path;
        }
      } catch (_) {
        // 字幕取得失敗は致命的ではない（動画はオフライン再生可能）
      }

      return OfflineCacheResult(
        success: true,
        videoPath: videoFile.path,
        subtitlePath: subtitlePath,
        resolution: resolution,
        sizeBytes: sizeBytes,
      );
    } catch (e) {
      return OfflineCacheResult(error: '$e');
    } finally {
      service.dispose();
    }
  }

  /// 1ストリームをファイルへダウンロードする。
  Future<_DlState> _downloadStream(
    YouTubeService service,
    StreamInfo info,
    File file,
    bool Function()? isCancelled,
    void Function(int received) onReceived,
  ) async {
    IOSink? sink;
    try {
      sink = file.openWrite();
      var received = 0;
      final stream = service.yt.videos.streamsClient.get(info);
      await for (final chunk in stream) {
        if (isCancelled?.call() ?? false) {
          await sink.close();
          return _DlState.cancelled;
        }
        sink.add(chunk);
        received += chunk.length;
        onReceived(received);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return received > 0 ? _DlState.ok : _DlState.failed;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      return _DlState.failed;
    }
  }

  /// 指定パスのキャッシュファイル（動画・字幕）を削除する。
  Future<void> deletePaths(String? videoPath, String? subtitlePath) async {
    for (final p in [videoPath, subtitlePath]) {
      if (p == null) continue;
      await _safeDelete(File(p));
    }
  }

  /// キャッシュ領域・documents 両方の offline ディレクトリ合計サイズ（バイト）。
  Future<int> totalCacheSize() async {
    var total = 0;
    for (final base in await _bothBaseDirs()) {
      final dir = Directory('${base.path}/$_subDirName');
      if (!await dir.exists()) continue;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    }
    return total;
  }

  Future<List<Directory>> _bothBaseDirs() async => [
        await getApplicationCacheDirectory(),
        await getApplicationDocumentsDirectory(),
      ];

  static int _resValue(String label) {
    final m = RegExp(r'(\d+)').firstMatch(label);
    return m != null ? int.parse(m.group(1)!) : 0;
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
