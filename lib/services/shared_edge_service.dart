import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/audio/shared_edges.dart';
import '../core/audio/wave_bands.dart';
import '../core/storage/app_boxes.dart';
import '../providers/data_provider.dart';
import 'waveform_cache.dart';

/// ほかの曲と共通の端（ロゴ・エンドカードなど。[SharedEdges]）を見つけて曲に残す。
/// 材料は保存済みの帯域の波形なので、音声を取り直さない
class SharedEdgeService {
  SharedEdgeService._();

  /// 読んだ両端の波形（1 曲 5KB ほど。音は変わらないので起動中は持っておく）
  static final _edges = <String, EdgeBands>{};

  /// テスト用: 読んだものを忘れる
  @visibleForTesting
  static void debugReset() => _edges.clear();

  /// 曲 [itemId] を解析する前に呼ぶ。この曲の端を返し、この曲が増えたことで
  /// 端が変わるほかの曲も保存する。失敗しても解析は止めない（今の値を返す）
  static Future<SharedEdge> update(
    LoopItemsNotifier items,
    String itemId,
    Int16List pcm,
    int sampleRate,
  ) async {
    final stored = items.byId(itemId)?.sharedEdge ?? SharedEdge.none;
    try {
      final self = await _edgeOf(itemId, pcm, sampleRate);
      if (self == null) return stored;
      _edges[itemId] = self;
      final all = await _library();
      final known = _known();
      final changes = await Isolate.run(() => SharedEdges.refresh(self, all, known));
      await items.saveSharedEdges(changes);
      return changes[itemId] ?? stored;
    } catch (e) {
      debugPrint('[SharedEdge] $itemId: $e');
      return stored;
    }
  }

  /// 解析済みの曲を一度だけ全部見比べる（この機能より前に解析した曲にも端を付ける）
  static Future<void> scanLibrary(LoopItemsNotifier items) async {
    try {
      final settings = AppBoxes.settings;
      if (settings.get(SettingsKeys.sharedEdgesScanned) == true) return;
      final all = await _library();
      if (all.length > SharedEdges.minPeers) {
        final known = _known();
        final found = await Isolate.run(() => {
              for (final e in all)
                if (SharedEdges.find(e, all) case final r
                    when r != (known[e.id] ?? SharedEdge.none))
                  e.id: r,
            });
        await items.saveSharedEdges(found);
      }
      await settings.put(SettingsKeys.sharedEdgesScanned, true);
    } catch (e) {
      debugPrint('[SharedEdge] 見比べに失敗: $e');
    }
  }

  static Map<String, SharedEdge> _known() => {
        for (final i in AppBoxes.loopItems.values) i.id: i.sharedEdge,
      };

  /// 帯域の波形がある全曲の両端
  static Future<List<EdgeBands>> _library() async {
    final ids = [for (final i in AppBoxes.loopItems.values) i.id];
    final missing = [
      for (final id in ids)
        if (!_edges.containsKey(id)) id,
    ];
    if (missing.isNotEmpty) {
      final paths = await WaveformCache.bandsPaths(missing);
      _edges.addAll(await Isolate.run(() => _readEdges(paths)));
    }
    return [for (final id in ids) ?_edges[id]];
  }

  static Map<String, EdgeBands> _readEdges(Map<String, String> paths) {
    final out = <String, EdgeBands>{};
    paths.forEach((id, path) {
      final f = File(path);
      if (!f.existsSync()) return;
      final bands = WaveBands.decode(f.readAsBytesSync());
      if (bands != null) out[id] = EdgeBands.of(id, bands);
    });
    return out;
  }

  /// 保存済みの帯域の波形があればそこから、無ければ PCM から
  static Future<EdgeBands?> _edgeOf(String id, Int16List pcm, int sampleRate) async {
    final memo = _edges[id];
    if (memo != null) return memo;
    final bands = await WaveformCache.loadBands(id);
    if (bands != null) return EdgeBands.of(id, bands);
    return Isolate.run(() {
      final b = WaveBands.fromPcm(pcm, sampleRate);
      return b == null ? null : EdgeBands.of(id, b);
    });
  }
}
