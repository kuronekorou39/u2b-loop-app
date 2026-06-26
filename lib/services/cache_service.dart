import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

/// YouTube動画と字幕をアプリ内にダウンロード保存し、オフライン再生を可能にするサービス。
///
/// muxed（音声+映像一体）ストリームを丸ごと保存するため、ネイティブのmux結合は不要。
/// 保存先は設定 `cache_to_documents` で切替（false=キャッシュ領域[既定], true=documents）。
/// 高解像度(1080p+)対応は将来 videoOnly+audioOnly のmux結合で別途実装する。
class CacheService {
  static const _settingsBox = 'settings';
  static const _storageKey = 'cache_to_documents';
  static const _subDirName = 'offline';

  /// 保存先ディレクトリ（設定に応じてキャッシュ領域 or documents）。
  Future<Directory> _cacheDir() async {
    final persistent = _persistent;
    final base = persistent
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

  /// [videoId] の動画(muxed)と字幕(SRT)をダウンロードして保存する。
  ///
  /// [onProgress] は 0.0〜1.0 の動画DL進捗。[isCancelled] が true を返したら中断。
  Future<OfflineCacheResult> downloadForOffline(
    String id,
    String videoId, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final service = YouTubeService();
    File? videoFile;
    IOSink? sink;
    try {
      final manifest = await service.getManifestWithFallback(videoId);
      final muxed = manifest.muxed.sortByVideoQuality();
      if (muxed.isEmpty) {
        return const OfflineCacheResult(
            error: '保存可能な音声付きストリームがありません（高解像度のみの動画）');
      }
      final info = muxed.last;
      final total = info.size.totalBytes;

      final dir = await _cacheDir();
      videoFile = File('${dir.path}/$id.mp4');
      sink = videoFile.openWrite();

      var received = 0;
      final stream = service.yt.videos.streamsClient.get(info);
      await for (final chunk in stream) {
        if (isCancelled?.call() ?? false) {
          await sink.close();
          await _safeDelete(videoFile);
          return const OfflineCacheResult(cancelled: true);
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (received <= 0) {
        await _safeDelete(videoFile);
        return const OfflineCacheResult(error: 'ダウンロードに失敗しました');
      }

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
        resolution: info.qualityLabel,
        sizeBytes: received,
      );
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (videoFile != null) await _safeDelete(videoFile);
      return OfflineCacheResult(error: '$e');
    } finally {
      service.dispose();
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

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
