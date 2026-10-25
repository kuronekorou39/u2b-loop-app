import 'dart:math';

import 'beat_grid.dart';

/// 段落表の 1 行: 入り口の候補（段落の頭、ミリ秒）と、その先 1 段落の平均 dB（ピーク比）
typedef EntrySection = ({double ms, double db});

/// 次曲の入り口を、前曲の出口の盛り上がりに合わせて選ぶ（純 Dart・副作用なし）。
///
/// DJ は次曲を必ず頭から入れるわけではない。前曲が盛り上がったまま終わるなら、
/// 次曲の静かなイントロは飛ばして同じくらい鳴っている段落から入れる。前曲が静かに
/// 終わるなら、静かなイントロをそのまま重ねる（ドロップがあれば [MixPointDetector] の
/// ドロップ合わせが切替点に当てる）。
///
/// 材料は曲の「音量の流れ」（[EnergyProfile.curve]、[EnergyProfile.curveStepMs] ごとの dB）と
/// 拍の格子。段落はフレーズ（8 小節）の頭で区切る（[BeatGrid.phraseGrid]）。
/// 格子が無ければ [fallbackPhraseMs] ごと
class EntryPlanner {
  EntryPlanner._();

  /// 出口と「同じくらい鳴っている」とみなす差（dB）
  static const similarDb = 3.0;

  /// 曲頭がこれ以上出口より静かなら「静かなイントロ」とみなして飛ばす候補を探す（dB）
  static const quietHeadDb = 3.0;

  /// 入り口を探す範囲（曲の長さに対する割合）。後ろすぎると曲の大半を捨ててしまう
  static const searchFraction = 0.5;

  /// 格子が無いときの 1 段落の長さ（ミリ秒）
  static const fallbackPhraseMs = 16000.0;

  /// 入り口の手前に最低限ほしい長さ（ミリ秒）。重ねる余地が無い候補は使わない
  static const minLeadMs = 2000.0;

  /// 1 段落の長さ（媒体ミリ秒）。格子が信用できればフレーズ、無ければ [fallbackPhraseMs]
  static double phraseMsFor(BeatGrid? grid) =>
      grid != null && grid.reliable
          ? grid.periodMs * BeatGrid.beatsPerBar * BeatGrid.barsPerPhrase
          : fallbackPhraseMs;

  /// 音量の流れ [curve]（[stepMs] ごとの dB）の [fromMs]〜[toMs] の平均。
  /// 範囲が曲の外にはみ出した分は無視する。1 点も無ければ −60
  static double meanDb(List<double> curve, double fromMs, double toMs,
      {required int stepMs}) {
    if (curve.isEmpty || toMs <= fromMs) return -60;
    final from = (fromMs / stepMs).floor().clamp(0, curve.length);
    final to = (toMs / stepMs).ceil().clamp(0, curve.length);
    if (to <= from) return from < curve.length ? curve[from] : -60;
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      sum += curve[i];
    }
    return sum / (to - from);
  }

  /// 段落表。先頭は曲頭（[leadingSilenceMs]。「頭から入れる」の意味で ms はそのまま）、
  /// 以降は曲の前半（[searchFraction]）にある段落の頭。
  /// 段落の頭は [grid] のフレーズの頭（[dropMs] = ドロップを段落の頭の基準に）。
  /// 格子が無ければ曲頭から [fallbackPhraseMs] ごと
  static List<EntrySection> sections(
    List<double> curve, {
    required int stepMs,
    BeatGrid? grid,
    double? dropMs,
    int leadingSilenceMs = 0,
  }) {
    final durationMs = curve.length * stepMs.toDouble();
    final head = leadingSilenceMs.toDouble();
    final phrase = phraseMsFor(grid);
    if (durationMs <= 0 || head >= durationMs) return const [];
    final result = <EntrySection>[
      (ms: head, db: meanDb(curve, head, head + phrase, stepMs: stepMs)),
    ];
    final limit = durationMs * searchFraction;
    final phrases = grid != null && grid.reliable ? grid.phraseGrid(dropMs) : null;
    // 次の段落の頭（ちょうど頭なら 1 つ先）
    double next(double ms) {
      if (phrases == null) return ms + phrase;
      final toNext = phrases.toNextBeatMs(ms);
      return ms + (toNext <= 0 ? phrases.periodMs : toNext);
    }
    for (var ms = next(head); ms < limit; ms = next(ms)) {
      if (ms - head < minLeadMs) continue;
      result.add((ms: ms, db: meanDb(curve, ms, ms + phrase, stepMs: stepMs)));
    }
    return result;
  }

  /// 入り口を選ぶ。曲頭から入れてよければ null（ドロップ合わせなど今までの決め方に任せる）。
  ///
  /// - 曲頭が出口と同じくらい鳴っている（または出口のほうが静か）→ null
  /// - 曲頭が出口より [quietHeadDb] 以上静か → 出口と同じくらい（[similarDb] 以内）鳴る
  ///   最初の段落の頭。無ければ、曲頭より [quietHeadDb] 以上大きい一番鳴っている段落。
  ///   それも無ければ null
  static double? entryMs({
    required double exitDb,
    required List<EntrySection> sections,
  }) {
    if (sections.length < 2) return null;
    final head = sections.first;
    if (head.db >= exitDb - quietHeadDb) return null;
    for (final s in sections.skip(1)) {
      if (s.db >= exitDb - similarDb) return s.ms;
    }
    EntrySection? loudest;
    for (final s in sections.skip(1)) {
      if (loudest == null || s.db > loudest.db) loudest = s;
    }
    if (loudest != null && loudest.db >= head.db + quietHeadDb) return loudest.ms;
    return null;
  }

  /// 出口の dB: 切断点 [cutMs] の手前 1 段落の平均
  static double exitDb(List<double> curve, double cutMs,
      {required int stepMs, BeatGrid? grid}) =>
      meanDb(curve, max(0, cutMs - phraseMsFor(grid)), cutMs, stepMs: stepMs);
}
