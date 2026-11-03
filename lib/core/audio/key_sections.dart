import 'dart:math';
import 'dart:typed_data';

import 'bpm_key_detector.dart';
import 'cq_chroma.dart';
import 'musical_key.dart';

/// キーの区切り 1 つ: [startMs]（動画の頭からのミリ秒）から次の区切りまでが [key]（'Gmin' 形式）
class KeySection {
  const KeySection(this.startMs, this.key);
  final int startMs;
  final String key;

  @override
  String toString() => '${startMs}ms:$key';
}

/// 曲の中の転調を求める（純Dart・副作用なし）。
///
/// 16 秒の窓を 8 秒ずつずらして窓ごとに 24 キーの当てはまり（Krumhansl のプロファイルとの相関）
/// を出し、「キーを変えるたびに罰点」を付けて全体で最も筋の通る並びを選ぶ（Viterbi）。
/// 近い関係のキー（平行調・同主調・5 度隣、[_sameFamily]）は窓ごとには見分けにくく、
/// 和音の中心が動いただけのことも多いので、その間の移りは罰点を軽くし、区切りにもしない。区切りのキーは窓ごとのラベルでなく、区切り全体の音を足して決め直す。
/// 境目は、両側のキーを 8 秒のブロックに当てはめ、後ろ側の方が合うようになる位置まで 1 秒刻みで詰める
class KeySectionDetector {
  KeySectionDetector._();

  static const _windowSec = 16.0;
  static const _hopSec = 8.0;
  static const _blockSec = 8.0;

  /// 窓 1 つの当てはまりの差（相関の差 × この倍率）と比べる、キーを変える罰点
  static const _scale = 10.0;
  static const _changeCost = 3.0;
  static const _relativeCost = 1.0;

  /// これより短い区切りは隣に混ぜる（窓の数。4 = 約 40 秒）
  static const _minSectionWindows = 4;

  /// [frames] は曲の範囲の [CqChroma.frames]、[startMs] はその先頭の時刻。
  /// 転調があるときだけ返す（一定なら空）
  static List<KeySection> detect(List<Float64List> frames, int sampleRate,
      {required int startMs}) {
    final fps = sampleRate / CqChroma.hop;
    final win = (_windowSec * fps).round(), hop = (_hopSec * fps).round();
    final starts = [for (var a = 0; a + win <= frames.length; a += hop) a];
    if (starts.length < _minSectionWindows * 2) return const [];

    final cost = <Float64List>[];
    for (final a in starts) {
      final r = scores(CqChroma.sum(frames, a, a + win));
      final c = Float64List(24);
      if (r != null) {
        final mx = r.reduce(max);
        for (var k = 0; k < 24; k++) {
          c[k] = (mx - r[k]) * _scale;
        }
      }
      cost.add(c);
    }
    final path = _viterbi(cost);

    // 近い関係のキーが続くあいだを 1 つの区切りに。比べる相手は直前の窓でなく区切りの最初の
    // キー（隣の隣へ少しずつ移る D# → A# → F のような +2 半音を、一続きと見なさないように）。
    // 短い区切りは隣へ、近い関係のキーが並べば 1 つに
    final runs = <_Run>[];
    var acc = Float64List(12);
    var anchor = path[0];
    for (var t = 0; t < path.length; t++) {
      if (t == 0 || !_sameFamily(path[t], anchor)) {
        runs.add(_Run(t, t + 1));
        acc = Float64List(12);
      } else {
        runs.last.to = t + 1;
      }
      // 基準 = この区切りでここまでに鳴った音の合計から決めたキー（1 つの窓の外れに引きずられない）
      final w = CqChroma.sum(frames, starts[t], starts[t] + win);
      for (var i = 0; i < 12; i++) {
        acc[i] += w[i];
      }
      anchor = _best(scores(acc)) ?? path[t];
    }
    int frameOf(int window) => starts[min(window, starts.length - 1)];
    int keyOf(_Run r, bool last) =>
        _best(scores(CqChroma.sum(frames, frameOf(r.from),
            last ? frames.length : frameOf(r.to)))) ??
        path[r.from];

    var changed = true;
    while (changed && runs.length > 1) {
      changed = false;
      var shortest = 0;
      for (var i = 1; i < runs.length; i++) {
        if (runs[i].length < runs[shortest].length) shortest = i;
      }
      if (runs[shortest].length < _minSectionWindows) {
        final r = runs.removeAt(shortest);
        if (shortest > 0 && (shortest == runs.length || runs[shortest - 1].length >= runs[shortest].length)) {
          runs[shortest - 1].to = r.to;
        } else {
          runs[shortest].from = r.from;
        }
        changed = true;
        continue;
      }
      for (var i = 0; i < runs.length; i++) {
        runs[i].key = keyOf(runs[i], i == runs.length - 1);
      }
      for (var i = 0; i + 1 < runs.length; i++) {
        if (_sameFamily(runs[i].key, runs[i + 1].key)) {
          runs[i].to = runs[i + 1].to;
          runs.removeAt(i + 1);
          changed = true;
          break;
        }
      }
    }
    if (runs.length < 2) return const [];
    for (var i = 0; i < runs.length; i++) {
      runs[i].key = keyOf(runs[i], i == runs.length - 1);
    }

    // 境目を詰める
    final block = (_blockSec * fps).round(), step = max(1, fps.round());
    double msOf(int frame) => startMs + frame * 1000 / fps;
    final out = <KeySection>[KeySection(startMs, _name(runs[0].key))];
    for (var i = 1; i < runs.length; i++) {
      final a = runs[i - 1].key, b = runs[i].key;
      var frame = frameOf(runs[i].from) + hop ~/ 2;
      bool bWins(int f) {
        if (f < 0 || f + block > frames.length) return false;
        final s = scores(CqChroma.sum(frames, f, f + block));
        return s != null && s[b] > s[a];
      }

      final margin = win;
      for (var f = max(0, frame - margin - block ~/ 2);
          f <= frame + margin - block ~/ 2;
          f += step) {
        if (bWins(f) && bWins(f + step) && bWins(f + step * 2)) {
          frame = f + block ~/ 2;
          break;
        }
      }
      out.add(KeySection(msOf(frame).round(), _name(b)));
    }
    return out;
  }

  /// 24 キーの相関（添字 = 主音 + 12 × 短調）。無音なら null
  static Float64List? scores(Float64List chroma) {
    final list = BpmKeyDetector.keyScores(chroma);
    return list;
  }

  static int? _best(Float64List? s) {
    if (s == null) return null;
    var best = 0;
    for (var k = 1; k < 24; k++) {
      if (s[k] > s[best]) best = k;
    }
    return best;
  }

  static String _name(int k) =>
      MusicalKey.name(k % 12, k < 12 ? KeyMode.major : KeyMode.minor);

  /// 同じキーとして扱う近い関係: 同じキー・平行調（Am と C）・同主調（Cm と C）・
  /// 5 度隣（Camelot ±1 の同じ A/B、C と G）。サビで和音の中心が動いただけのことが多く、
  /// DJ の相性でももともと合う扱い。これより遠い移り（半音上げなど）だけを転調として出す
  static bool _sameFamily(int a, int b) {
    if (a == b || _relative(a, b)) return true;
    if (a % 12 == b % 12) return true; // 同主調
    if ((a < 12) != (b < 12)) return false;
    final d = (a % 12 - b % 12 + 12) % 12;
    return d == 5 || d == 7; // 5 度隣
  }

  static bool _relative(int a, int b) {
    if ((a < 12) == (b < 12)) return false;
    final major = a < 12 ? a : b, minor = a < 12 ? b : a;
    // 短調の主音の短 3 度上が平行長調
    return (minor % 12 + 3) % 12 == major;
  }

  static List<int> _viterbi(List<Float64List> cost) {
    final t = cost.length;
    double move(int i, int j) =>
        i == j ? 0 : (_sameFamily(i, j) ? _relativeCost : _changeCost);
    var acc = Float64List.fromList(cost[0]);
    final back = <Int32List>[];
    for (var s = 1; s < t; s++) {
      final next = Float64List(24);
      final bk = Int32List(24);
      for (var j = 0; j < 24; j++) {
        var best = double.infinity, bi = 0;
        for (var i = 0; i < 24; i++) {
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
    for (var i = 1; i < 24; i++) {
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

class _Run {
  _Run(this.from, this.to);
  int from, to;
  int key = 0;
  int get length => to - from;
}
