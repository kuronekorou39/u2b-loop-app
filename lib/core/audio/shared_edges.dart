import 'dart:math';
import 'dart:typed_data';

import 'wave_bands.dart';

/// 曲の両端だけを切り出した帯域の波形（ほかの曲と比べる材料。isolate に渡せる値だけ）。
/// [head] は曲頭から順、[tail] は曲末から逆順に、1 点につき低・中・高の 3 つが並ぶ
class EdgeBands {
  const EdgeBands({
    required this.id,
    required this.stepMs,
    required this.lengthMs,
    required this.head,
    required this.tail,
  });

  final String id;
  final int stepMs;

  /// 曲全体の長さ
  final int lengthMs;
  final Uint8List head;
  final Uint8List tail;

  /// [bands] の両端 [SharedEdges.windowMs] ぶんを切り出す
  factory EdgeBands.of(String id, WaveBands bands) {
    final n = bands.length;
    final w = min(n, SharedEdges.windowMs ~/ bands.stepMs);
    final head = Uint8List(w * 3), tail = Uint8List(w * 3);
    for (var i = 0; i < w; i++) {
      head[i * 3] = bands.low[i];
      head[i * 3 + 1] = bands.mid[i];
      head[i * 3 + 2] = bands.high[i];
      final j = n - 1 - i;
      tail[i * 3] = bands.low[j];
      tail[i * 3 + 1] = bands.mid[j];
      tail[i * 3 + 2] = bands.high[j];
    }
    return EdgeBands(
        id: id, stepMs: bands.stepMs, lengthMs: bands.durationMs, head: head, tail: tail);
  }
}

/// ほかの曲と共通の端（ロゴ・エンドカードなど、曲でない部分）の長さ
class SharedEdge {
  const SharedEdge({this.headMs = 0, this.tailMs = 0});

  static const none = SharedEdge();

  final int headMs;
  final int tailMs;

  bool get isNone => headMs == 0 && tailMs == 0;

  @override
  bool operator ==(Object other) =>
      other is SharedEdge && other.headMs == headMs && other.tailMs == tailMs;

  @override
  int get hashCode => Object.hash(headMs, tailMs);

  @override
  String toString() => 'SharedEdge(head: $headMs, tail: $tailMs)';
}

/// 別の動画なのに同じ音が続く端は、曲ではなくロゴやエンドカードとみなす（純 Dart）。
///
/// 両端の帯域の波形を、端をそろえて ±[maxLagMs] ずらしながら 1 秒ごとに比べる。
/// - フェードアウト同士は「だんだん小さくなる」形が似るので、大きさではなく隣の点との差
///   （音の動き）で比べる
/// - カードはいくつかの部分をつないだもので、部分ごとに動画間のずれが違う。ずれを 1 つに
///   決めず、ずれごとに [minRun] 秒以上続く一致を集める
/// - 同じ曲の別の動画も一致するので、1 秒ごとに [minPeers] 曲以上と一致した範囲だけを端とし、
///   [sameSongMs] 以上一致する相手は同じ曲として数えない
///
/// 2026-11 の 51 曲で決めた値: カードのある 43 曲のうち 40 曲で検出、カードの無い 8 曲は誤検出 0
class SharedEdges {
  SharedEdges._();

  /// 端から比べる長さ
  static const windowMs = 40000;

  /// 比べる 1 かたまりの長さ
  static const blockMs = 1000;

  /// 端をそろえるときにずらす幅（動画ごとの末尾の無音の違い）
  static const maxLagMs = 3000;

  /// 相手を絞るのに見る、端からの長さ（カードは端にあるので、ここで一致しない相手は外す）
  static const probeMs = 12000;

  /// 同じ音とみなす相関
  static const sameBlock = 0.85;

  /// 相手を絞るときの相関（絞るだけなので甘く。カードの一部だけが 0.85 に届かない組がある）
  static const probeBlock = 0.7;

  /// 同じずれで続けて一致しないと数えない秒数（偶然の 1 秒を拾わない）
  static const minRun = 3;

  /// これより短い端は偶然（短い効果音やカウントなど）
  static const minSharedMs = 5000;

  /// これ以上一致する相手は、ロゴではなく同じ曲の別の動画
  static const sameSongMs = 35000;

  /// 共通とみなすのに必要な、一致するほかの曲の数（自分を入れて 3 曲）
  static const minPeers = 2;

  /// 端の途中で一致が切れても続きとみなす秒数（圧縮の違いや短い雑音）
  static const maxHoles = 2;

  /// 両端を足して曲のこの割合を超えたら、端ではない（短い動画が丸ごと一致した）
  static const maxShare = 0.5;

  /// 1 点あたりの動きの 2 乗がこれ未満なら無音（一致に数えない）
  static const _quietPerPoint = 12;

  /// [self] の両端が [others] と共通する長さ
  static SharedEdge find(EdgeBands self, Iterable<EdgeBands> others) {
    final peers = [
      for (final o in others)
        if (o.id != self.id && o.stepMs == self.stepMs) o,
    ];
    if (peers.length < minPeers) return SharedEdge.none;
    final head = _edgeMs(self.head, [for (final o in peers) o.head], self.stepMs);
    final tail = _edgeMs(self.tail, [for (final o in peers) o.tail], self.stepMs);
    if (head + tail > self.lengthMs * maxShare) return SharedEdge.none;
    return SharedEdge(headMs: head, tailMs: tail);
  }

  /// 曲 [self] が増えた（解析した）ときに、端の長さが変わる曲とその新しい値。
  /// [self] と、今の値（[stored]）より先まで [self] と一致した曲だけを数え直す
  static Map<String, SharedEdge> refresh(
    EdgeBands self,
    List<EdgeBands> all,
    Map<String, SharedEdge> stored,
  ) {
    final out = <String, SharedEdge>{};
    final mine = find(self, all);
    if (mine != (stored[self.id] ?? SharedEdge.none)) out[self.id] = mine;
    final head = _motion(self.head), tail = _motion(self.tail);
    for (final o in all) {
      if (o.id == self.id || o.stepMs != self.stepMs) continue;
      final now = stored[o.id] ?? SharedEdge.none;
      final grew = _beyond(_matchedBlocks(_motion(o.head), head, self.stepMs), now.headMs) ||
          _beyond(_matchedBlocks(_motion(o.tail), tail, self.stepMs), now.tailMs);
      if (!grew) continue;
      final r = find(o, all);
      if (r != now) out[o.id] = r;
    }
    return out;
  }

  /// [pcm] の [edge] の部分を無音にしたコピー（端が無ければそのまま）
  static Int16List muted(Int16List pcm, int sampleRate, SharedEdge edge) {
    if (edge.isNone) return pcm;
    final out = Int16List.fromList(pcm);
    final head = min(out.length, edge.headMs * sampleRate ~/ 1000);
    final tail = min(out.length, edge.tailMs * sampleRate ~/ 1000);
    out.fillRange(0, head, 0);
    out.fillRange(out.length - tail, out.length, 0);
    return out;
  }

  static bool _beyond(List<int> blocks, int storedMs) =>
      blocks.isNotEmpty && (blocks.last + 1) * blockMs > storedMs;

  /// [self]（外側から順）のうち、[minPeers] 曲以上と同じ音が外側から続く長さ
  static int _edgeMs(Uint8List self, List<Uint8List> peers, int stepMs) {
    final block = blockMs ~/ stepMs;
    final blocks = (self.length ~/ 3) ~/ block;
    if (blocks == 0) return 0;
    final a = _motion(self);
    final cover = Int32List(blocks);
    for (final p in peers) {
      for (final k in _matchedBlocks(a, _motion(p), stepMs)) {
        cover[k]++;
      }
    }
    var last = -1, holes = 0;
    for (var k = 0; k < blocks; k++) {
      if (cover[k] >= minPeers) {
        last = k;
        holes = 0;
      } else if (++holes > maxHoles) {
        break;
      }
    }
    final ms = (last + 1) * blockMs;
    return ms >= minSharedMs ? ms : 0;
  }

  /// [a] の何ブロック目が [b] と同じ音か（昇順。どちらも [_motion] の形）。
  /// 関係のない相手・同じ曲の別の動画は空
  static List<int> _matchedBlocks(Int16List a, Int16List b, int stepMs) {
    final block = blockMs ~/ stepMs;
    final maxLag = maxLagMs ~/ stepMs;
    final blocks = (a.length ~/ 3) ~/ block;
    if (blocks == 0 || b.length ~/ 3 < block) return const [];
    // まず端の近くだけ見る（大半の相手はここで外れる）
    final probe = probeMs ~/ blockMs;
    var near = false;
    for (var lag = -maxLag; lag <= maxLag && !near; lag++) {
      near = _scan(a, b, lag, block, probe, probeBlock, null) > 0;
    }
    if (!near) return const [];
    final hit = Uint8List(blocks);
    var longest = 0;
    for (var lag = -maxLag; lag <= maxLag; lag++) {
      longest = max(longest, _scan(a, b, lag, block, blocks, sameBlock, hit));
    }
    if (longest * blockMs >= sameSongMs) return const [];
    return [
      for (var k = 0; k < blocks; k++)
        if (hit[k] == 1) k,
    ];
  }

  /// [lag] 点ずらして [minRun] 秒以上続く一致を探し、その合計の秒数を返す（[hit] に印を付ける）。
  /// 続く一致は必ず [minRun] 個おきの位置のどれかを含むので、そこだけ先に調べる
  static int _scan(Int16List a, Int16List b, int lag, int block, int limit, double threshold,
      Uint8List? hit) {
    final ia = max(0, lag), ib = max(0, -lag);
    final n = min(limit, min((a.length ~/ 3 - ia) ~/ block, (b.length ~/ 3 - ib) ~/ block));
    bool same(int k) => _same(a, ia + k * block, b, ib + k * block, block, threshold);
    var total = 0, floor = 0;
    for (var k = minRun - 1; k < n;) {
      if (!same(k)) {
        k += minRun;
        continue;
      }
      var s = k, e = k + 1;
      while (s > floor && same(s - 1)) {
        s--;
      }
      while (e < n && same(e)) {
        e++;
      }
      if (e - s >= minRun) {
        total += e - s;
        if (hit != null) {
          for (var j = s; j < e; j++) {
            final self = (ia + j * block + block ~/ 2) ~/ block;
            if (self < hit.length) hit[self] = 1;
          }
        }
      }
      floor = e + 1;
      k = e + minRun;
    }
    return total;
  }

  /// 隣の点との差（3 帯域の並びのまま）
  static Int16List _motion(Uint8List v) {
    final m = Int16List(v.length);
    for (var i = 3; i < v.length; i++) {
      m[i] = v[i] - v[i - 3];
    }
    return m;
  }

  /// [x] と [y] から [n] 点が同じ音か（どちらかがほぼ無音なら違う扱い）
  static bool _same(Int16List a, int x, Int16List b, int y, int n, double threshold) {
    var ab = 0, aa = 0, bb = 0;
    final ia = x * 3, ib = y * 3;
    for (var i = 0; i < n * 3; i++) {
      final p = a[ia + i], q = b[ib + i];
      ab += p * q;
      aa += p * p;
      bb += q * q;
    }
    final quiet = _quietPerPoint * n;
    if (aa < quiet || bb < quiet) return false;
    return ab / sqrt(aa.toDouble() * bb) >= threshold;
  }
}
