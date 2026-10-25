import 'dart:math';

import '../../models/loop_item.dart';
import 'musical_key.dart';

/// 解析済みのテンポ(BPM)/キーから、2曲の「つなぎやすさ」を数値化する。
///
/// DJ の慣習に合わせて
/// - テンポは倍/半テンポ（120 と 60 と 240）を同じものとして扱う
///   （解析結果にもその曖昧さが残るため、区別すると誤判定が増える）
/// - キーは Camelot ホイールで同一・平行調・隣接を「合う」とする
/// 未解析の曲は「分からない」なので低めの中立値にして、解析済み同士より後ろに回す。
class TrackCompatibility {
  TrackCompatibility._();

  /// テンポ合わせで許容する速度変化の上限（±%）。これを超えると不自然に聞こえる
  static const maxTempoAdjustPercent = 8.0;

  /// スコア上、テンポ差がこれ以上なら 0 点とみなす（±%）
  static const tempoScoreZeroPercent = 12.0;

  /// 未解析（BPM/キーが不明）の要素に与える中立値
  static const unknownScore = 0.35;

  /// [to] のテンポを [from] に合わせるために必要な速度倍率。
  /// 倍/半テンポを考慮し、最も 1 に近い倍率を返す。どちらか不明なら null
  static double? tempoRatio(double? from, double? to) {
    if (from == null || to == null || from <= 0 || to <= 0) return null;
    var best = from / to;
    for (final candidate in [from / (to * 2), from / (to / 2)]) {
      if ((log(candidate)).abs() < (log(best)).abs()) best = candidate;
    }
    return best;
  }

  /// テンポ差（±%、倍/半を同一視）。どちらか不明なら null
  static double? tempoDiffPercent(double? a, double? b) {
    final r = tempoRatio(a, b);
    return r == null ? null : (r - 1).abs() * 100;
  }

  /// テンポの近さ 0〜1
  static double tempoScore(double? a, double? b) {
    final diff = tempoDiffPercent(a, b);
    if (diff == null) return unknownScore;
    return max(0.0, 1 - diff / tempoScoreZeroPercent);
  }

  /// キーの相性 0〜1。Camelot で合えば 1、番号が2つ離れた同モードは 0.4、他は 0
  static double keyScore(String? a, String? b) {
    final ca = MusicalKey.camelot(a), cb = MusicalKey.camelot(b);
    if (ca == null || cb == null) return unknownScore;
    if (MusicalKey.isCompatible(a, b)) return 1.0;
    final na = int.parse(ca.substring(0, ca.length - 1));
    final nb = int.parse(cb.substring(0, cb.length - 1));
    final sameMode = ca[ca.length - 1] == cb[cb.length - 1];
    final diff = (na - nb) % 12;
    if (sameMode && (diff == 2 || diff == 10)) return 0.4;
    return 0.0;
  }

  /// 音量の流れの差（出る曲の終わりと入る曲の頭の dB 差）がこれ以内なら流れは満点
  static const flowFreeDb = 3.0;

  /// 音量の流れの差がこれ以上なら流れは 0 点（dB）
  static const flowZeroDb = 15.0;

  /// 音量の流れの近さ 0〜1: [a] の終わり（tailDb）と [b] の頭（headDb）の差。
  /// どちらか未計測なら中立値。入り口を選ぶ機能が静かなイントロを飛ばしてくれるので
  /// 重みは軽めだが、同じくらいの盛り上がりで渡せる曲を少し前に出す
  static double flowScore(LoopItem a, LoopItem b) {
    final tail = a.tailDb;
    final head = b.headDb;
    if (tail == null || head == null) return unknownScore;
    final diff = max(0.0, (tail - head).abs() - flowFreeDb);
    return max(0.0, 1 - diff / (flowZeroDb - flowFreeDb));
  }

  /// [a] の後に [b] をつなぐときの総合スコア 0〜1（テンポ 5 : キー 3 : 音量の流れ 2）
  static double score(LoopItem a, LoopItem b) =>
      0.5 * tempoScore(a.bpm, b.bpm) +
      0.3 * keyScore(a.musicalKey, b.musicalKey) +
      0.2 * flowScore(a, b);

  static bool isAnalyzed(LoopItem item) =>
      item.bpm != null || item.musicalKey != null;

  /// [items] を、先頭から順に「直前の曲と最も相性のよい曲」を選ぶ貪欲法で並べ替える。
  /// [startIndex] の曲を先頭に固定する。未解析の曲は元の順のまま末尾に回す
  static List<LoopItem> order(List<LoopItem> items, {int startIndex = 0}) {
    if (items.length < 2) return List.of(items);
    final analyzed = <LoopItem>[];
    final unknown = <LoopItem>[];
    final start = items[startIndex.clamp(0, items.length - 1)];
    for (final item in items) {
      if (identical(item, start)) continue;
      (isAnalyzed(item) ? analyzed : unknown).add(item);
    }
    final result = <LoopItem>[start];
    var prev = start;
    while (analyzed.isNotEmpty) {
      var bestIdx = 0;
      var bestScore = -1.0;
      for (var i = 0; i < analyzed.length; i++) {
        final s = score(prev, analyzed[i]);
        if (s > bestScore) {
          bestScore = s;
          bestIdx = i;
        }
      }
      prev = analyzed.removeAt(bestIdx);
      result.add(prev);
    }
    return result..addAll(unknown);
  }

  /// [target] と相性のよい順に [candidates] を並べる（target 自身と未解析は除く）
  static List<LoopItem> rank(LoopItem target, Iterable<LoopItem> candidates) {
    final scored = <(LoopItem, double)>[
      for (final c in candidates)
        if (c.id != target.id && isAnalyzed(c)) (c, score(target, c)),
    ];
    scored.sort((x, y) => y.$2.compareTo(x.$2));
    return [for (final s in scored) s.$1];
  }

  /// 一覧表示用の説明。例: '126 BPM (+5%) · Amin (8A) ✓'
  /// （% は [target] から見て [other] がどれだけ速いか。倍/半は折り畳む）
  static String describe(LoopItem target, LoopItem other) {
    final parts = <String>[];
    if (other.bpm != null) {
      final ratio = tempoRatio(target.bpm, other.bpm);
      final pct = ratio == null ? '' : _signedPercent((1 / ratio - 1) * 100);
      parts.add('${other.bpm!.round()} BPM$pct');
    }
    if (other.musicalKey != null) {
      final ok = MusicalKey.isCompatible(target.musicalKey, other.musicalKey);
      parts.add('${MusicalKey.display(other.musicalKey)}${ok ? ' ✓' : ''}');
    }
    return parts.join(' · ');
  }

  static String _signedPercent(double pct) {
    final r = pct.round();
    if (r == 0) return ' (±0%)';
    return ' (${r > 0 ? '+' : ''}$r%)';
  }
}
