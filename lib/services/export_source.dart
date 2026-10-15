import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/loop_item.dart';
import 'cache_service.dart';
import 'export_service.dart';
import 'playback/hq_audio.dart';
import 'ranged_downloader.dart';
import 'youtube_client_info.dart';

/// 書き出しの解像度。YouTube の一体型は 360p しか無いので、それ以上は
/// 映像専用ストリームを落として高音質の音声と結合してから切り出す
enum ExportQuality {
  p1080(1080, '1080p'),
  p720(720, '720p'),
  p480(480, '480p'),
  p360(360, '360p（そのまま・速い）');

  const ExportQuality(this.height, this.label);

  final int height;
  final String label;

  /// 結合が要るか（360p は再生に使っている一体型をそのまま切り出す）
  bool get needsMerge => this != p360;

  static ExportQuality fromName(String? name) =>
      values.firstWhere((q) => q.name == name, orElse: () => p720);
}

/// 書き出しに渡す入力。[tempFiles] は書き出しが終わったら [dispose] で消す
class ExportInput {
  ExportInput(this.path, {this.tempFiles = const [], this.note});

  /// MediaExtractor に渡すパスか URL
  final String path;
  final List<File> tempFiles;

  /// 希望どおりにならなかった時の一言（「高画質で取れなかったので 360p で」など）
  final String? note;

  Future<void> dispose() async {
    for (final f in tempFiles) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}

/// YouTube の曲を高画質・高音質で書き出すための入力を用意する。
///
/// - 音声のみ: 再生用に落としてある高音質の音声（HqAudio、mp4/AAC）をそのまま使う
/// - MP4 で 360p 超: VISIONOS クライアントの映像専用（mp4/avc1）を落とし、
///   高音質の音声とネイティブで結合（再エンコード無し）した一時ファイルを使う
/// - それ以外・失敗時: [fallbackUri]（再生に使っている一体型 360p の URL）
///
/// ローカル動画とオフライン保存済みは [fallbackUri] をそのまま使う（呼び出し側が渡す）
class ExportSource {
  ExportSource._();

  /// 解像度を聞く意味があるか（YouTube をネットから書き出す時だけ。
  /// ローカルとオフライン保存済みは手元のファイルをそのまま切り出す）
  static bool canPickQuality(LoopItem item) =>
      item.isYouTube &&
      item.videoId != null &&
      CacheService.offlineVideoPath(item) == null;

  static const _dirName = 'export_src';

  /// [heights]（取れる映像の高さ）から [target] 以下で最大のもの。
  /// 無ければ一番小さいもの。候補が無ければ null（純粋な計算。テスト用に分けてある）
  static int? pickHeight(Iterable<int> heights, int target) {
    int? best;
    int? smallest;
    for (final h in heights) {
      if (smallest == null || h < smallest) smallest = h;
      if (h <= target && (best == null || h > best)) best = h;
    }
    return best ?? smallest;
  }

  static Future<ExportInput> prepare(
    LoopItem item, {
    required ExportFormat format,
    required ExportQuality quality,
    required String fallbackUri,
    void Function(String status)? onStatus,
  }) async {
    final videoId = item.videoId;
    if (!item.isYouTube ||
        videoId == null ||
        CacheService.offlineVideoPath(item) != null) {
      return ExportInput(fallbackUri);
    }
    try {
      if (format == ExportFormat.audioOnly) {
        onStatus?.call('高音質の音声を取得中...');
        final hq = await HqAudio.fetch(videoId);
        if (hq != null && hq.endsWith('.mp4')) return ExportInput(hq);
        return ExportInput(fallbackUri,
            note: hq == null ? '高音質の音声を取れなかったので 96kbps で書き出します' : null);
      }
      if (!quality.needsMerge) return ExportInput(fallbackUri);
      return await _prepareMerged(videoId, quality, fallbackUri, onStatus);
    } catch (e) {
      debugPrint('[ExportSource] 高画質の準備に失敗: $e');
      return ExportInput(fallbackUri, note: '高画質で取れなかったので 360p で書き出します');
    }
  }

  static Future<ExportInput> _prepareMerged(
    String videoId,
    ExportQuality quality,
    String fallbackUri,
    void Function(String status)? onStatus,
  ) async {
    final dir = await _dir();
    final temps = <File>[];
    ExportInput fallback(String note) {
      for (final f in temps) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      return ExportInput(fallbackUri, note: note);
    }

    onStatus?.call('映像の情報を取得中...');
    final yt = YoutubeExplode();
    final StreamManifest manifest;
    try {
      manifest = await yt.videos.streamsClient
          .getManifest(videoId, ytClients: [YouTubeClientInfo.visionOs])
          .timeout(const Duration(seconds: 30));
    } finally {
      yt.close();
    }

    // 映像: mp4/avc1 の映像専用から希望の高さ以下で最大のもの（MediaMuxer が扱える形式）
    final videos = manifest.videoOnly
        .where((v) =>
            v.container == StreamContainer.mp4 &&
            v.videoCodec.startsWith('avc'))
        .toList();
    final height = pickHeight(videos.map((v) => v.videoResolution.height), quality.height);
    if (height == null) return fallback('高画質の映像が無いので 360p で書き出します');
    final video = videos.firstWhere((v) => v.videoResolution.height == height);

    // 音声: 再生用に落としてある高音質（mp4/AAC）。webm しか無ければ mp4 を取り直す
    onStatus?.call('高音質の音声を取得中...');
    var audioPath = await HqAudio.fetch(videoId, manifest: manifest);
    if (audioPath == null || !audioPath.endsWith('.mp4')) {
      final mp4Audio = manifest.audioOnly
          .where((a) => a.container == StreamContainer.mp4)
          .toList();
      if (mp4Audio.isEmpty) return fallback('音声を取れなかったので 360p で書き出します');
      final a = mp4Audio.withHighestBitrate();
      final f = File('${dir.path}/${videoId}_a.mp4');
      temps.add(f);
      final st = await RangedDownloader.download(a.url.toString(), a.size.totalBytes, f);
      if (st != DownloadState.ok) return fallback('音声を取れなかったので 360p で書き出します');
      audioPath = f.path;
    }

    onStatus?.call('映像（${video.qualityLabel}）を取得中...');
    final videoFile = File('${dir.path}/${videoId}_v.mp4');
    temps.add(videoFile);
    final st = await RangedDownloader.download(
        video.url.toString(), video.size.totalBytes, videoFile);
    if (st != DownloadState.ok) return fallback('映像を取れなかったので 360p で書き出します');

    onStatus?.call('映像と音声を結合中...');
    final merged = File('${dir.path}/${videoId}_${height}p.mp4');
    temps.add(merged);
    final ok = await ExportService().muxVideoAudio(
      videoPath: videoFile.path,
      audioPath: audioPath,
      outputPath: merged.path,
    );
    if (!ok) return fallback('結合に失敗したので 360p で書き出します');
    // 結合済みがあれば映像の一時ファイルはもう要らない
    try {
      await videoFile.delete();
    } catch (_) {}
    temps.remove(videoFile);
    return ExportInput(merged.path, tempFiles: temps);
  }

  static Future<Directory> _dir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/$_dirName');
    if (await dir.exists()) {
      // 前回の消し残し（途中で落ちた時など）
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    await dir.create(recursive: true);
    return dir;
  }
}
