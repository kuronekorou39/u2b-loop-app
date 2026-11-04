import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/audio/wave_bands.dart';

/// 曲の帯域の波形（[WaveBands]。無ければ null）。保存されたら読み直す
final waveBandsProvider = FutureProvider.family<WaveBands?, String>((ref, itemId) {
  final sub = WaveformCache.bandsChanged
      .where((id) => id == itemId)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return WaveformCache.loadBands(itemId);
});

/// 生成済み波形（0.0〜1.0 × 4000点）をアイテム単位でファイルに保存しておく。
///
/// 以前は再生のたびに YouTube の音声をダウンロードし直して波形を作っていたが、
/// 波形自体は 8bit に量子化すれば 4KB/曲 なので、全曲ぶん残しても容量は問題にならない
/// （保存期間や上限は設けない）。音声 DL が要るのは、波形が無いか解析が必要なときだけ。
class WaveformCache {
  WaveformCache._();

  static const _dirName = 'waveforms';
  static const _extension = '.wf';

  /// 帯域の波形（[WaveBands]）。波形と同じフォルダに置くので、まとめて消える
  static const _bandsExtension = '.wb';

  static final _bandsChanged = StreamController<String>.broadcast();

  /// 読んだ帯域の波形（同期で見たいところ用。おまかせのつなぎ方選び）
  static final _bandsMemo = <String, WaveBands>{};

  /// 読み込み済みなら帯域の波形（無ければ null。裏で読み始める）
  static WaveBands? cachedBands(String itemId) {
    final b = _bandsMemo[itemId];
    if (b == null) unawaited(loadBands(itemId));
    return b;
  }

  /// 帯域の波形を保存した曲の ID
  static Stream<String> get bandsChanged => _bandsChanged.stream;

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _file(String itemId) async =>
      File('${(await _dir()).path}/$itemId$_extension');

  static Future<File> _bandsFile(String itemId) async =>
      File('${(await _dir()).path}/$itemId$_bandsExtension');

  static Future<bool> bandsExist(String itemId) async =>
      (await _bandsFile(itemId)).exists();

  /// 無ければ null
  static Future<WaveBands?> loadBands(String itemId) async {
    try {
      final f = await _bandsFile(itemId);
      if (!await f.exists()) return null;
      final b = WaveBands.decode(await f.readAsBytes());
      if (b != null) _bandsMemo[itemId] = b;
      return b;
    } catch (e) {
      debugPrint('[WaveformCache] 帯域の読込失敗: $e');
      return null;
    }
  }

  /// 解析用の PCM から帯域の波形を求めて保存する（isolate で計算）
  static Future<void> saveBandsFromPcm(String itemId, Int16List pcm, int sampleRate) async {
    try {
      final bands = await Isolate.run(() => WaveBands.fromPcm(pcm, sampleRate));
      if (bands == null) return;
      await (await _bandsFile(itemId)).writeAsBytes(bands.encode(), flush: true);
      _bandsMemo[itemId] = bands;
      _bandsChanged.add(itemId);
    } catch (e) {
      debugPrint('[WaveformCache] 帯域の保存失敗: $e');
    }
  }

  /// 帯域の波形がまだ無ければ、PCM を受け取って作る受け口を [analysis]（解析の受け口）に
  /// 足して返す。どちらも要らなければ null（PCM を取り出さない）
  static Future<void Function(Int16List, int)?> pcmSinkWithBands(
      String itemId, void Function(Int16List, int)? analysis) async {
    if (await bandsExist(itemId)) return analysis;
    return (pcm, sampleRate) {
      analysis?.call(pcm, sampleRate);
      unawaited(saveBandsFromPcm(itemId, pcm, sampleRate));
    };
  }

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
      final b = await _bandsFile(itemId);
      if (await b.exists()) await b.delete();
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
