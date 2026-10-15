import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/storage/app_boxes.dart';
import '../ranged_downloader.dart';

/// 一度開いた YouTube の曲の映像（一体型 360p）と高音質の音声を、しばらく端末に残す。
///
/// - 2 回目以降は通信なしで開ける。AB ループで A 点へ戻るたびの Range 要求が無くなり、
///   ストリーム URL の失効（数時間）で途中から再生できなくなる経路も消える
/// - 消えてよい使い捨て。オフライン保存（CacheService、消えない置き場）とは別物で、
///   オフライン保存があればそちらが常に優先される
/// - 合計が上限（[limitBytes]、設定で変更）を超えたら古い順に消す
/// - **長い曲（[maxDuration] 超）は残さない**。1 曲で上限の多くを使い、他の曲を押し出すため。
///   繰り返し聴く長い曲はオフライン保存すればよい。
///   ただし高音質の音声は再生に要るので落とし、`.long` 印を付けて最新 [keepLongFiles] 件だけ残す
///
/// 映像は再生が始まってから少し遅らせて裏で落とす（[cacheVideoLater]。出だしの帯域を取り合わない）。
/// プリロードは時間に余裕があるので、落としてから開く（[fetchVideo]）
class MediaCache {
  MediaCache._();

  static const dirName = 'media_cache';

  /// これより長い曲は残さない
  static const maxDuration = Duration(minutes: 15);

  /// 長い曲の高音質の音声を残す件数（2 枚のプレイヤーの分）
  static const keepLongFiles = 2;

  /// 上限の選択肢（MB）と既定
  static const limitOptionsMb = [500, 1024, 2048, 4096];
  static const defaultLimitMb = 1024;

  /// 再生開始から映像を落とし始めるまで
  static const videoDelay = Duration(seconds: 5);

  /// これより小さいファイルは落とし損ねとみなす
  static const minBytes = 100 * 1024;

  static int get limitMb {
    try {
      return AppBoxes.settings.get(SettingsKeys.mediaCacheLimitMb,
          defaultValue: defaultLimitMb) as int;
    } catch (_) {
      return defaultLimitMb;
    }
  }

  static set limitMb(int mb) =>
      AppBoxes.settings.put(SettingsKeys.mediaCacheLimitMb, mb);

  static int get limitBytes => limitMb * 1024 * 1024;

  /// サイズとビットレートからの長さの見積もり（manifest には長さが無い）
  static Duration estimateDuration(int bytes, int bitsPerSecond) =>
      bitsPerSecond <= 0
          ? Duration.zero
          : Duration(milliseconds: bytes * 8 * 1000 ~/ bitsPerSecond);

  static bool isTooLong(Duration d) => d > maxDuration;

  /// [path] がこのキャッシュの管理下か（波形生成などが使い終わっても消してはいけない）
  static bool isManagedPath(String path) =>
      path.replaceAll('\\', '/').contains('/$dirName/');

  static bool _oldDirSwept = false;

  static Future<Directory> dir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/$dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    if (!_oldDirSwept) {
      _oldDirSwept = true;
      // v1.91〜v1.93 の高音質の音声の置き場（一時領域/hq_audio）。今はここに統合した
      try {
        final old = Directory('${(await getTemporaryDirectory()).path}/hq_audio');
        if (await old.exists()) await old.delete(recursive: true);
      } catch (_) {}
    }
    return dir;
  }

  // ---- 映像 ----

  /// 映像のファイル名 `<videoId>.v<itag>.mp4`
  static final _videoName = RegExp(r'^([^.]+)\.v(\d+)\.mp4$');

  static String videoFileName(String videoId, int itag) =>
      '$videoId.v$itag.mp4';

  static final _inFlight = <String, Future<String?>>{};

  /// 映像が残っていればそのパス（通信なし）。使った順を保つため触っておく
  static Future<String?> existingVideo(String videoId) async {
    try {
      final d = await dir();
      await for (final e in d.list()) {
        if (e is! File) continue;
        final m = _videoName.firstMatch(_name(e.path));
        if (m == null || m.group(1) != videoId) continue;
        if (!await isComplete(e)) continue;
        await touch(e.path);
        return e.path;
      }
    } catch (_) {}
    return null;
  }

  /// 再生に使っている一体型（[YouTubeService.pickStreamUrl] と同じ選び方）を落とす。
  /// 残っていれば即返す。一体型が無い・長すぎる・落とせない時は null
  static Future<String?> fetchVideo(
    String videoId,
    StreamManifest manifest, {
    bool Function()? isCancelled,
  }) {
    final running = _inFlight[videoId];
    if (running != null) return running;
    // whenComplete に Future を返す式を渡すと自分自身を待って完了しない（HqAudio.fetch 参照）
    final future = _fetchVideo(videoId, manifest, isCancelled).whenComplete(() {
      _inFlight.remove(videoId);
    });
    _inFlight[videoId] = future;
    return future;
  }

  static Future<String?> _fetchVideo(
    String videoId,
    StreamManifest manifest,
    bool Function()? isCancelled,
  ) async {
    final ready = await existingVideo(videoId);
    if (ready != null) return ready;
    final muxed = manifest.muxed.sortByVideoQuality();
    if (muxed.isEmpty) return null;
    final info = muxed.last;
    final length =
        estimateDuration(info.size.totalBytes, info.bitrate.bitsPerSecond);
    if (isTooLong(length)) {
      debugPrint('[MediaCache] $videoId: ${length.inMinutes} 分あるので映像は残さない');
      return null;
    }
    final d = await dir();
    final file = File('${d.path}/${videoFileName(videoId, info.tag)}');
    final part = File('${file.path}.part');
    final state = await RangedDownloader.download(
      info.url.toString(),
      info.size.totalBytes,
      part,
      isCancelled: isCancelled,
    );
    if (state != DownloadState.ok || !await isComplete(part)) {
      await _delete(part);
      return null;
    }
    try {
      await part.rename(file.path);
    } catch (_) {
      await _delete(part);
      return null;
    }
    debugPrint('[MediaCache] $videoId: 映像 itag ${info.tag} '
        '${info.size.totalMegaBytes.toStringAsFixed(1)}MB を残した');
    unawaited(enforceLimit());
    return file.path;
  }

  /// 再生が落ち着いてから裏で映像を落とす（待たない）。
  /// [isCancelled] が true なら始めない（その曲をもう聴いていない）
  static void cacheVideoLater(
    String videoId,
    StreamManifest manifest, {
    bool Function()? isCancelled,
  }) {
    Future.delayed(videoDelay, () {
      if (isCancelled?.call() ?? false) return;
      unawaited(fetchVideo(videoId, manifest));
    });
  }

  // ---- 掃除 ----

  /// 使った順を保つ（掃除は古い順）
  static Future<void> touch(String path) async {
    try {
      await File(path).setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// 上限を超えた分を古い順に消す。長い曲の印付きは最新 [keepLongFiles] 件だけ。
  /// 落とし損ねの .part は 1 時間たったら消す
  static Future<void> enforceLimit() async {
    try {
      final d = await dir();
      final entries = <CacheEntry>[];
      final now = DateTime.now();
      await for (final e in d.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        if (e.path.endsWith('.part')) {
          if (now.difference(stat.modified) > const Duration(hours: 1)) {
            await _delete(e);
          }
          continue;
        }
        entries.add(CacheEntry(_name(e.path), stat.size, stat.modified));
      }
      for (final name in pickEvictions(entries, limitBytes)) {
        await _delete(File('${d.path}/$name'));
      }
    } catch (e) {
      debugPrint('[MediaCache] 掃除に失敗: $e');
    }
  }

  /// 消すファイル名（純粋な計算。テスト用に分けてある）。
  /// 長い曲の印（`.long.`）付きは新しい [keepLongFiles] 件を残して消し、
  /// 残りの合計が [limit] を超えていれば古い順に消す
  static List<String> pickEvictions(List<CacheEntry> entries, int limit) {
    final out = <String>[];
    final sorted = [...entries]..sort((a, b) => b.modified.compareTo(a.modified));
    final kept = <CacheEntry>[];
    var long = 0;
    for (final e in sorted) {
      if (e.name.contains('.long.')) {
        if (++long > keepLongFiles) {
          out.add(e.name);
          continue;
        }
      }
      kept.add(e);
    }
    var total = kept.fold<int>(0, (s, e) => s + e.size);
    // kept は新しい順。後ろ（古い方）から消す
    for (final e in kept.reversed) {
      if (total <= limit) break;
      out.add(e.name);
      total -= e.size;
    }
    return out;
  }

  static Future<int> totalBytes() async {
    var total = 0;
    try {
      final d = await dir();
      await for (final e in d.list()) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  static Future<void> clear() async {
    try {
      final d = await dir();
      await for (final e in d.list()) {
        if (e is File) await _delete(e);
      }
    } catch (_) {}
  }

  static Future<bool> isComplete(File f) async {
    try {
      return await f.exists() && await f.length() >= minBytes;
    } catch (_) {
      return false;
    }
  }

  static String _name(String path) => path.replaceAll('\\', '/').split('/').last;

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 掃除の判断に使う 1 ファイル分の情報
class CacheEntry {
  const CacheEntry(this.name, this.size, this.modified);

  final String name;
  final int size;
  final DateTime modified;
}
