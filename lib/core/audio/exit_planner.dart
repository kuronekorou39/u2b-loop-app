import 'dart:math';

import 'beat_grid.dart';
import 'entry_planner.dart';

/// 前の曲の出口を選ぶ（純 Dart・副作用なし。[EntryPlanner] の出口版）。
///
/// DJ は静かで長いアウトロを最後まで流さず、最後の盛り上がり（サビ）の終わりで次の曲へ渡す。
/// 曲の後ろのほうにあるフレーズの頭のうち、
/// - その手前 1 段落が曲の一番鳴る段落と同じくらい（[loudDb] 以内）鳴っていて
/// - そこから今の切断点までが手前より [quietTailDb] 以上静か
/// な一番後ろの頭を出口にする。無ければ null（今までどおりの切断点）。
///
/// 材料は [EntryPlanner] と同じ: 音量の流れ（[EnergyProfile.curve]）と拍の格子のフレーズ
class ExitPlanner {
  ExitPlanner._();

  /// 切り落とす残りが、最後の盛り上がりよりこれ以上静かなら「静かなアウトロ」（dB）
  static const quietTailDb = 4.0;

  /// 最後の盛り上がりとみなす、曲の一番鳴る段落との差（dB）
  static const loudDb = 3.0;

  /// 出口を探すのは曲のこの割合より後ろだけ（曲の大半を捨てない）
  static const searchFrom = 0.6;

  /// 本体の音量からこれだけ下がったら、フェードアウトが始まったとみなす（dB）
  static const fadeStartDb = 3.0;

  /// 終わりがこれ以上下がっていなければフェードアウトではない（dB）
  static const fadeDepthDb = 12.0;

  /// フェードアウトとみなす長さの範囲（ミリ秒）。短いのは最後の音の余韻、
  /// 長いのは静かな終盤（曲の一部なので切らない）
  static const minFadeMs = 6000.0, maxFadeMs = 45000.0;

  /// 曲の終わりのフェードアウトが始まる位置（ミリ秒）。無ければ null。
  ///
  /// 本体（曲の真ん中 6 割の中央値）の音量に最後に届いている所の直後。フェードの途中で
  /// 切り替えると、小さくなった前の曲から次の曲へ音量が 5〜9dB 跳ねて聞こえる
  static double? fadeStartMs(List<double> curve, {required int stepMs}) {
    final n = curve.length;
    if (n < 10) return null;
    final middle = curve.sublist((n * 0.2).floor(), (n * 0.8).ceil())..sort();
    final body = middle[middle.length ~/ 2];
    var last = n - 1;
    while (last >= 0 && curve[last] < body - fadeStartDb) {
      last--;
    }
    if (last < 0 || curve[n - 1] > body - fadeDepthDb) return null;
    final startMs = (last + 1) * stepMs.toDouble();
    final durationMs = n * stepMs.toDouble();
    final fadeMs = durationMs - startMs;
    if (fadeMs < minFadeMs || fadeMs > maxFadeMs || startMs < durationMs * searchFrom) {
      return null;
    }
    return startMs;
  }

  /// 出口（ミリ秒）。早めに切らなくてよければ null。
  /// [cutMs] は今の切断点（アウトロ点・曲末の無音の手前など）、
  /// [dropMs] はフレーズの頭の基準（[BeatGrid.phraseGrid]）、[leadingSilenceMs] は曲頭で飛ばす長さ
  static double? exitMs(
    List<double> curve, {
    required int stepMs,
    required double cutMs,
    BeatGrid? grid,
    double? dropMs,
    int leadingSilenceMs = 0,
  }) {
    final durationMs = curve.length * stepMs.toDouble();
    final head = leadingSilenceMs.toDouble();
    final end = min(cutMs, durationMs);
    final phrase = EntryPlanner.phraseMsFor(grid);
    if (durationMs <= 0 || end <= head || !phrase.isFinite || phrase <= 0) {
      return null;
    }
    final phrases = grid != null && grid.reliable ? grid.phraseGrid(dropMs) : null;
    final period = phrases?.periodMs ?? phrase;
    if (!period.isFinite || period <= 0) return null;
    // 段落の頭は番号 × 周期で数える（足し込むと位相 0.9999… の格子で前に進まない。EntryPlanner と同じ）
    final origin = phrases == null ? head : phrases.floorBeatMs(head);
    double db(double from, double to) =>
        EntryPlanner.meanDb(curve, from, to, stepMs: stepMs);

    // 曲の中で丸ごと収まる段落の頭と、その段落の dB
    final heads = <({double ms, double db})>[];
    for (var k = 0;; k++) {
      final ms = origin + k * period;
      if (!(ms + period <= end)) break;
      if (ms < head) continue;
      heads.add((ms: ms, db: db(ms, ms + period)));
    }
    if (heads.length < 2) return null;
    final peak = heads.map((h) => h.db).reduce(max);
    final from = durationMs * searchFrom;
    // 後ろから: 手前の段落が盛り上がっていて、そこから先が静かな頭
    for (var i = heads.length - 1; i >= 1; i--) {
      final b = heads[i].ms;
      if (b < from) break;
      final before = heads[i - 1].db;
      if (before < peak - loudDb) continue;
      if (before - db(b, end) >= quietTailDb) return b;
    }
    return null;
  }
}
