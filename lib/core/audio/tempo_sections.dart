import 'dart:math';
import 'dart:typed_data';

import 'beat_grid.dart';
import 'bpm_key_detector.dart';
import 'music_span_detector.dart';

/// テンポの区切り 1 つ: [startMs]（動画の頭からのミリ秒）から次の区切りまでが [bpm]
class TempoSection {
  const TempoSection(this.startMs, this.bpm);
  final int startMs;
  final double bpm;

  /// 保存の形（[startMs, bpm, startMs, bpm, …]）にする / から戻す
  static List<double> flatten(List<TempoSection> sections) =>
      [for (final s in sections) ...[s.startMs.toDouble(), s.bpm]];
  static List<TempoSection> unflatten(List<double> flat) => [
        for (var i = 0; i + 1 < flat.length; i += 2)
          TempoSection(flat[i].round(), flat[i + 1]),
      ];

  @override
  String toString() => '${startMs}ms:$bpm';
}

/// 曲の中のテンポの区切りを求める（純Dart・副作用なし）。
///
/// 8 秒の窓を 4 秒ずつずらして窓ごとのテンポの当てはまり（[BpmKeyDetector.tempogram]）を出し、
/// 「テンポを変えるたびに罰点」を付けて全体で最も筋の通るテンポの並びを選ぶ（Viterbi）。
/// 窓ごとの 1 位をそのまま並べないのは、一定のテンポの曲でも 1 位が 2:3 や倍/半分の候補と
/// 行き来するから（2026-11 に手元の曲で、157 BPM の曲の 1 位が 157 と 106 を往復していた）。
/// 4% 未満の動きは罰点を軽くして揺れとして扱い、区切りにしない。
///
/// 境目は、粗い位置の前後で両側の拍の格子を 4 秒のブロックに当てはめ（[BpmKeyDetector.gridLock]）、
/// 後ろ側の格子の方が合うようになる位置まで 1 秒刻みで詰める。
class TempoSectionDetector {
  TempoSectionDetector._();

  static const _windowSec = 8.0;
  static const _hopSec = 4.0;
  static const _blockSec = 4.0;

  /// テンポを変える罰点（窓 1 つの当てはまりの差は 0〜1）。1〜4 のどれでも結果は同じだった
  static const _changeCost = 2.0;

  /// これより小さい動き（オクターブ比）は揺れ: 約 4%
  static const _driftOctaves = 0.06;

  /// 区切りの長さの下限（窓の数）。これより短い区切りは隣に混ぜる
  static const _minSectionWindows = 4;

  /// [env] は曲の範囲だけを切り出した立ち上がり（時刻は動画のまま）、[startMs] は範囲の始まり。
  /// 区切りが 2 つ以上あるときだけ返す（テンポが一定なら空）
  static List<TempoSection> detect(OnsetEnvelope env, {required int startMs}) {
    final fps = env.fps;
    final n = env.full.length;
    final win = (_windowSec * fps).round(), hop = (_hopSec * fps).round();
    final starts = [for (var a = 0; a + win <= n; a += hop) a];
    if (starts.length < _minSectionWindows * 2) return const [];

    // 窓ごとの当てはまり。拍のはっきりしない窓はどのテンポでも同じ（前後に任せる）
    final grams = [for (final a in starts) BpmKeyDetector.tempogram(env.slice(a, a + win))];
    final bpms = grams.firstWhere((g) => g != null, orElse: () => null)?.bpms;
    if (bpms == null) return const [];
    final k = bpms.length;
    final cost = <Float64List>[];
    for (final tg in grams) {
      final c = Float64List(k);
      if (tg != null) {
        final mx = tg.score.reduce(max);
        if (mx >= MusicSpanDetector.beatScoreThreshold) {
          for (var j = 0; j < k; j++) {
            c[j] = 1 - tg.score[j] / mx;
          }
        }
      }
      cost.add(c);
    }
    final path = _viterbi(cost, bpms);

    // 揺れを超える動きで切り、短い区切りを混ぜ、倍/半分は同じテンポとして扱う
    var sections = <_Run>[];
    for (var t = 0; t < path.length; t++) {
      if (t == 0 || _octaves(bpms[path[t]], bpms[path[t - 1]]) >= _driftOctaves) {
        sections.add(_Run(t, t + 1));
      } else {
        sections.last.to = t + 1;
      }
    }
    double median(_Run r, double main) {
      final v = [
        for (var t = r.from; t < r.to; t++) _foldTo(bpms[path[t]], main),
      ]..sort();
      return v[v.length ~/ 2];
    }

    double mainOf(List<_Run> runs) {
      final longest = runs.reduce((a, b) => b.length > a.length ? b : a);
      final v = [for (var t = longest.from; t < longest.to; t++) bpms[path[t]]]..sort();
      return v[v.length ~/ 2];
    }

    var changed = true;
    while (changed && sections.length > 1) {
      changed = false;
      final main = mainOf(sections);
      for (final r in sections) {
        r.bpm = median(r, main);
      }
      // 隣とほぼ同じテンポなら 1 つに
      for (var i = 0; i + 1 < sections.length; i++) {
        if (_octaves(sections[i].bpm, sections[i + 1].bpm) < _driftOctaves) {
          sections[i].to = sections[i + 1].to;
          sections.removeAt(i + 1);
          changed = true;
          break;
        }
      }
      if (changed) continue;
      // 一番短い区切りが短すぎれば、テンポの近い方の隣に混ぜる
      var shortest = 0;
      for (var i = 1; i < sections.length; i++) {
        if (sections[i].length < sections[shortest].length) shortest = i;
      }
      final r = sections[shortest];
      if (r.length < _minSectionWindows) {
        final prev = shortest > 0 ? sections[shortest - 1] : null;
        final next = shortest + 1 < sections.length ? sections[shortest + 1] : null;
        final intoPrev = next == null ||
            (prev != null && _octaves(prev.bpm, r.bpm) <= _octaves(next.bpm, r.bpm));
        if (intoPrev) {
          prev!.to = r.to;
        } else {
          next.from = r.from;
        }
        sections.removeAt(shortest);
        changed = true;
      }
    }
    if (sections.length < 2) return const [];

    // 区切りごとの拍の格子（テンポは格子の精密な値に）
    final grids = <BeatGrid?>[];
    for (var i = 0; i < sections.length; i++) {
      final from = starts[sections[i].from];
      final to = i + 1 < sections.length ? starts[sections[i + 1].from] : n;
      grids.add(BpmKeyDetector.detectBeatGrid(env.slice(from, to), sections[i].bpm));
    }

    // 境目を詰める: 窓 t（[t*hop, t*hop+win)）から後ろのテンポになったので、境目はおよそ
    // t*hop + hop/2。その前後 8 秒で、後ろの格子の方が 3 ブロック続けて合う最初の位置
    final onset = BpmKeyDetector.weightedOnset(env);
    final block = (_blockSec * fps).round(), step = fps.round();
    final out = <TempoSection>[TempoSection(startMs, _round1(grids[0]?.bpm ?? sections[0].bpm))];
    for (var i = 1; i < sections.length; i++) {
      final a = grids[i - 1], b = grids[i];
      var frame = starts[sections[i].from] + hop ~/ 2;
      if (a != null && b != null) {
        final margin = (_windowSec * fps).round();
        bool bWins(int k) =>
            k >= 0 &&
            k + block <= n &&
            BpmKeyDetector.gridLock(env, onset, b, k, k + block) >
                BpmKeyDetector.gridLock(env, onset, a, k, k + block);
        for (var k = max(0, frame - margin - block ~/ 2);
            k <= frame + margin - block ~/ 2;
            k += step) {
          if (bWins(k) && bWins(k + step) && bWins(k + step * 2)) {
            frame = k + block ~/ 2;
            break;
          }
        }
      }
      out.add(TempoSection(
          env.timeMs(frame.toDouble()).round(), _round1(b?.bpm ?? sections[i].bpm)));
    }
    return out;
  }

  static double _round1(double v) => (v * 10).round() / 10;

  static double _octaves(double a, double b) => (log(a / b) / ln2).abs();

  /// 倍/半分にすると [main] とほぼ同じ（揺れの範囲）なら、その値（ハーフタイム・ダブルタイムは
  /// 同じテンポ）。そうでなければ [bpm] のまま（100 → 150 のような本当の変化は寄せない）
  static double _foldTo(double bpm, double main) {
    for (final f in const [0.25, 0.5, 2.0, 4.0]) {
      if (_octaves(bpm * f, main) < _driftOctaves) return bpm * f;
    }
    return bpm;
  }

  /// 窓ごとの罰点 [cost]（テンポ [bpms] の並び）から、変化の罰点込みで最も安い並びの添字
  static List<int> _viterbi(List<Float64List> cost, Float64List bpms) {
    final k = bpms.length, t = cost.length;
    final logB = Float64List.fromList([for (final b in bpms) log(b) / ln2]);
    double move(int i, int j) {
      final r = (logB[i] - logB[j]).abs();
      return r < _driftOctaves ? r * 5 : _changeCost;
    }

    var acc = Float64List.fromList(cost[0]);
    final back = <Int32List>[];
    for (var s = 1; s < t; s++) {
      final next = Float64List(k);
      final bk = Int32List(k);
      for (var j = 0; j < k; j++) {
        var best = double.infinity, bi = 0;
        for (var i = 0; i < k; i++) {
          final c = acc[i] + move(i, j);
          if (c < best) {
            best = c;
            bi = i;
          }
        }
        next[j] = best + cost[s][j];
        bk[j] = bi;
      }
      acc = next;
      back.add(bk);
    }
    var j = 0;
    for (var i = 1; i < k; i++) {
      if (acc[i] < acc[j]) j = i;
    }
    final path = List<int>.filled(t, 0);
    path[t - 1] = j;
    for (var s = t - 1; s > 0; s--) {
      path[s - 1] = back[s - 1][path[s]];
    }
    return path;
  }
}

/// 窓の添字の範囲 [from, to)
class _Run {
  _Run(this.from, this.to);
  int from, to;
  double bpm = 0;
  int get length => to - from;
}
