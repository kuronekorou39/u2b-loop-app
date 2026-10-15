import 'dart:io';

import 'package:http/http.dart' as http;

enum DownloadState { ok, cancelled, failed }

/// googlevideo の adaptive ストリームを Range ヘッダで分割ダウンロードする。
///
/// youtube_explode の get() は adaptive ストリームで途中失敗するため自前で実装。
/// オフライン保存（CacheService）と高音質音声（HqAudio）で共用。
class RangedDownloader {
  RangedDownloader._();

  /// googlevideo が 1 リクエストで返す単位に合わせる
  static const chunkBytes = 9 * 1024 * 1024;

  /// [url] を [file] へ落とす。[total] が 0 以下なら終端を応答サイズから推定する。
  /// 途中で 200/206 以外が返ったら [DownloadState.failed]（書いた分は呼び出し側が消す）
  static Future<DownloadState> download(
    String url,
    int total,
    File file, {
    bool Function()? isCancelled,
    void Function(int received)? onReceived,
    void Function(String reason)? onFailed,
    Duration requestTimeout = const Duration(seconds: 60),
  }) async {
    final client = http.Client();
    IOSink? sink;
    try {
      sink = file.openWrite();
      var start = 0;
      var guard = 0;
      while (total <= 0 || start < total) {
        if (isCancelled?.call() ?? false) {
          await sink.close();
          return DownloadState.cancelled;
        }
        if (++guard > 2000) break; // 暴走防止
        final end = (total > 0 && start + chunkBytes - 1 >= total)
            ? total - 1
            : start + chunkBytes - 1;
        final res = await client
            .get(Uri.parse(url), headers: {'Range': 'bytes=$start-$end'})
            .timeout(requestTimeout);
        if (res.statusCode != 200 && res.statusCode != 206) {
          onFailed?.call('HTTP ${res.statusCode}（${start ~/ 1024}KB 取得済み）');
          await sink.close();
          return DownloadState.failed;
        }
        if (res.bodyBytes.isEmpty) break;
        sink.add(res.bodyBytes);
        start += res.bodyBytes.length;
        onReceived?.call(start);
        // total不明時は、要求量より少なければ終端とみなす
        if (total <= 0 && res.bodyBytes.length < chunkBytes) break;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (start == 0) onFailed?.call('応答が空');
      return start > 0 ? DownloadState.ok : DownloadState.failed;
    } catch (e) {
      onFailed?.call(e.toString().split('\n').first);
      try {
        await sink?.close();
      } catch (_) {}
      return DownloadState.failed;
    } finally {
      client.close();
    }
  }
}
