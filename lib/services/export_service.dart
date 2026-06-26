import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

enum ExportFormat { mp4, audioOnly }

class ExportResult {
  final bool success;

  /// 保存先の表示用パス（ギャラリー保存時は "Movies/U2BLoop/foo.mp4" 等、
  /// 共有フォールバック時は一時ファイルの絶対パス）
  final String? outputPath;

  /// 端末のギャラリー/ミュージックへ直接保存済みか。
  /// false の場合は呼び出し側で [shareExported] による共有が必要（Android 9以前）。
  final bool savedToGallery;
  final String? error;
  const ExportResult({
    required this.success,
    this.outputPath,
    this.savedToGallery = false,
    this.error,
  });
}

class ExportService {
  static const _channel = MethodChannel('com.u2bloop/export');

  /// AB区間をトリミングしてファイルに書き出す
  Future<ExportResult> exportRegion({
    required String inputUri,
    required int startMs,
    required int endMs,
    required ExportFormat format,
    required String title,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('exportRegion', {
        'inputUri': inputUri,
        'startMs': startMs,
        'endMs': endMs,
        'audioOnly': format == ExportFormat.audioOnly,
        'title': title,
      });

      if (result == null) {
        return const ExportResult(success: false, error: '結果が返されませんでした');
      }

      final success = result['success'] as bool? ?? false;
      return ExportResult(
        success: success,
        outputPath: result['outputPath'] as String?,
        savedToGallery: result['savedToGallery'] as bool? ?? false,
        error: result['error'] as String?,
      );
    } on PlatformException catch (e) {
      return ExportResult(success: false, error: e.message);
    }
  }

  /// 別々にダウンロードした映像専用/音声専用ファイルを1つのMP4へ結合する
  /// （ネイティブMediaMuxerでremux、再エンコードなし）。高解像度オフライン保存用。
  /// 成功時は true。
  Future<bool> muxVideoAudio({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('muxVideoAudio', {
        'videoPath': videoPath,
        'audioPath': audioPath,
        'outputPath': outputPath,
      });
      return result?['success'] as bool? ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 書き出した一時ファイルを共有シート経由で保存/送信する。
  ///
  /// - ファイルをDartのメモリに読み込まずパスで渡すため、長尺MP4でもOOMしない。
  /// - 共有時のファイル名は元ファイルのbasenameがそのまま使われる
  ///   （share_plus 10.x はパス指定XFileの fileNameOverrides を無視するため、
  ///    ネイティブ側で `<タイトル>.<拡張子>` のクリーンな名前を付けている）。
  /// - 受信側アプリがコピーし終える前に消えるのを防ぐため、ここでは一時ファイルを
  ///   削除しない。古い書き出しは次回 [exportRegion] 実行時にネイティブ側でまとめて掃除する。
  Future<void> shareExported({
    required String outputPath,
    required ExportFormat format,
    String? subject,
  }) async {
    final mime = format == ExportFormat.audioOnly ? 'audio/mp4' : 'video/mp4';
    await Share.shareXFiles(
      [XFile(outputPath, mimeType: mime)],
      subject: subject,
    );
  }
}
