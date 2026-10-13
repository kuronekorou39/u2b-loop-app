import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 生成済み波形（0.0〜1.0 × 4000点）をアイテム単位でファイルに保存しておく。
///
/// 以前は再生のたびに YouTube の音声をダウンロードし直して波形を作っていたが、
/// 波形自体は 8bit に量子化すれば 4KB/曲 なので、全曲ぶん残しても容量は問題にならない
/// （保存期間や上限は設けない）。音声 DL が要るのは、波形が無いか解析が必要なときだけ。
class WaveformCache {
  WaveformCache._();

  static const _dirName = 'waveforms';
  static const _extension = '.wf';

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _file(String itemId) async =>
      File('${(await _dir()).path}/$itemId$_extension');

  static Future<bool> exists(String itemId) async =>
      (await _file(itemId)).exists();

  /// 無ければ null
  static Future<List<double>?> load(String itemId) async {
    try {
      final f = await _file(itemId);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      return [for (final b in bytes) b / 255.0];
    } catch (e) {
      debugPrint('[WaveformCache] 読込失敗: $e');
      return null;
    }
  }

  static Future<void> save(String itemId, List<double> waveform) async {
    if (waveform.isEmpty) return;
    try {
      final bytes = Uint8List(waveform.length);
      for (var i = 0; i < waveform.length; i++) {
        bytes[i] = (waveform[i].clamp(0.0, 1.0) * 255).round();
      }
      await (await _file(itemId)).writeAsBytes(bytes, flush: true);
    } catch (e) {
      debugPrint('[WaveformCache] 保存失敗: $e');
    }
  }

  static Future<void> delete(String itemId) async {
    try {
      final f = await _file(itemId);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 件数と合計バイト数（設定画面の表示用）
  static Future<(int count, int bytes)> stats() async {
    var count = 0, bytes = 0;
    try {
      await for (final e in (await _dir()).list()) {
        if (e is File && e.path.endsWith(_extension)) {
          count++;
          bytes += await e.length();
        }
      }
    } catch (_) {}
    return (count, bytes);
  }

  static Future<void> clear() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[WaveformCache] 削除失敗: $e');
    }
  }
}
