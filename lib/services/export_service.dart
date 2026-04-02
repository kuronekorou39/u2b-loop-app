import 'package:flutter/services.dart';

enum ExportFormat { mp4, audioOnly }

class ExportResult {
  final bool success;
  final String? outputPath;
  final String? error;
  const ExportResult({required this.success, this.outputPath, this.error});
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
        error: result['error'] as String?,
      );
    } on PlatformException catch (e) {
      return ExportResult(success: false, error: e.message);
    }
  }
}
