import 'dart:math';

import 'dart:typed_data';

import 'bpm_key_detector.dart';
import 'cq_chroma.dart';

/// 動画の中で曲が鳴っている範囲。
///
/// YouTube の動画は頭と終わりにトーク・OP・ED の語りなど曲でない部分が付いていることがあり、
/// アニメの本編のように全体が曲でないものもある。BPM・キー・拍の格子はこの範囲だけで求め、
/// クロスフェードの入り口と切り替え点もこの範囲の中から選ぶ。
class MusicSpan {
  const MusicSpan({
    required this.isMusic,
    required this.startMs,
    required this.endMs,
    this.steadyBeat = true,
  });

  /// 範囲が分からない（短すぎる）ときの「全体が曲」
  static const whole = MusicSpan(isMusic: true, startMs: 0, endMs: null);

  /// 曲ではない（拍のはっきりした部分がほとんど無い）
  static const notMusic = MusicSpan(isMusic: false, startMs: 0, endMs: null);

  /// 曲と判定したか。false なら BPM・キー・拍の格子は出さない
  final bool isMusic;

  /// 曲の始まり（動画の頭からのミリ秒）
  final int startMs;

  /// 曲の終わり（動画の頭からのミリ秒）。null = 解析した終わりまで曲
  final int? endMs;

  /// 一定の拍がある曲か。false = 拍ははっきりしないが和音のある曲（テンポを揺らして歌う
  /// バラードなど）。BPM・拍の格子は出さず、キーだけ出す
  final bool steadyBeat;

  @override
  String toString() => !isMusic
      ? '曲ではない'
      : '曲${steadyBeat ? '' : '（拍なし）'} ${startMs}ms〜${endMs ?? '終わり'}';
}

/// 保存する形の曲の範囲（無音と同じく、頭から・お尻から何ミリ秒が曲でないか）
class MusicSpanInfo {
  const MusicSpanInfo({
    required this.headMs,
    required this.tailMs,
    required this.notMusic,
    this.noSteadyBeat = false,
  });

  /// [lengthMs] は解析した PCM の長さ。[truncated] なら曲末まで届いていないので
  /// お尻は分からない（null）
  factory MusicSpanInfo.of(MusicSpan span, {required int lengthMs, required bool truncated}) {
    if (!span.isMusic) return const MusicSpanInfo(headMs: 0, tailMs: null, notMusic: true);
    final end = span.endMs;
    return MusicSpanInfo(
      headMs: span.startMs,
      tailMs: truncated ? null : (end == null ? 0 : max(0, lengthMs - end)),
      notMusic: false,
      noSteadyBeat: !span.steadyBeat,
    );
  }

  final int headMs;
  final int? tailMs;
  final bool notMusic;

  /// 拍ははっきりしないが和音のある曲（[MusicSpan.steadyBeat] が false）
  final bool noSteadyBeat;
}

/// 曲の範囲を立ち上がりの時系列から求める（純Dart・副作用なし）。
///
/// 1. 粗く: 8 秒の窓を 4 秒ずつずらし、窓ごとに自己相関の山の高さ（拍のはっきりさ）を見る。
///    2026-11 に手元の音源で測ると、読み上げのトークは 0.04〜0.09、ふつうの曲は 0.4〜0.7、
///    ジャズで 0.17〜0.6、ピアノソロで 0.09〜0.4、無音は 0。
/// 2. 細かく: 粗い境目の前後だけ、曲の範囲で求めた拍の格子を当てはめ、4 秒のブロックを
///    1 秒ずつずらして「拍の位置に立ち上がりが乗っているか」を見る。テンポが分かっていれば
///    短いブロックでも判定がぶれない（同じ測定でトーク 0.3〜1.2、曲 1.5〜4）。境目の誤差は 1〜3 秒
class MusicSpanDetector {
  MusicSpanDetector._();

  /// 和音のはっきりさ（16 秒窓のクロマと 24 キーの相関の最大）がこれ以上なら和音がある。
  /// 2026-11 の測定: 読み上げのトーク 0.22〜0.37、ふつうの曲 0.67〜0.88、
  /// テンポを揺らすバラード（When I Think About The Future）0.81
  static const tonalThreshold = 0.5;

  static const _tonalWindowSec = 16.0;
  static const _tonalHopSec = 8.0;

  /// 拍がはっきりしないとき（[detect] が曲ではないと判定したとき）に、和音で曲の範囲を探す。
  /// [frames] は動画全体の [CqChroma.frames]。和音のある窓が 2 つ続く最初から最後までを
  /// 「拍のない曲」とし（8 秒単位）、ほとんど無ければ曲ではない
  static MusicSpan tonalSpan(List<Float64List> frames, int sampleRate) {
    final fps = sampleRate / CqChroma.hop;
    final win = (_tonalWindowSec * fps).round(), hop = (_tonalHopSec * fps).round();
    final tonal = <bool>[];
    for (var a = 0; a + win <= frames.length; a += hop) {
      final s = BpmKeyDetector.keyScores(CqChroma.sum(frames, a, a + win));
      tonal.add(s != null && s.reduce(max) >= tonalThreshold);
    }
    var first = -1, last = -1, count = 0;
    for (var i = 0; i + 1 < tonal.length; i++) {
      if (tonal[i] && tonal[i + 1]) {
        if (first < 0) first = i;
        last = i + 1;
      }
    }
    if (first < 0) return MusicSpan.notMusic;
    for (var i = first; i <= last; i++) {
      if (tonal[i]) count++;
    }
    final startFrame = first * hop, endFrame = min(frames.length, last * hop + win);
    if ((endFrame - startFrame) / fps < _minMusicSec ||
        count / (last - first + 1) < _minBeatRatio) {
      return MusicSpan.notMusic;
    }
    int ms(int frame) => (frame * 1000 / fps).round();
    return MusicSpan(
      isMusic: true,
      startMs: ms(startFrame),
      endMs: endFrame >= frames.length ? null : ms(endFrame),
      steadyBeat: false,
    );
  }

  static const _windowSec = 8.0;
  static const _hopSec = 4.0;

  /// 粗い窓で「拍がある」とみなす自己相関の山の高さ
  static const beatScoreThreshold = 0.15;

  /// 細かいブロックで「拍の位置に乗っている」とみなす値（ブロック内の平均からの標準偏差の何倍か）
  static const lockThreshold = 1.5;

  static const _blockSec = 4.0;

  /// 曲とみなす長さの下限と、範囲の中で拍のある窓の割合の下限
  static const _minMusicSec = 20.0;
  static const _minBeatRatio = 0.5;

  static MusicSpan detect(OnsetEnvelope env) {
    final fps = env.fps;
    final n = env.full.length;
    final win = (_windowSec * fps).round(), hop = (_hopSec * fps).round();
    // 窓が 3 つ取れないほど短い動画は判定しない（今までどおり全体を曲として扱う）
    if (n < win + hop * 2) return MusicSpan.whole;

    final beat = <bool>[];
    for (var a = 0; a + win <= n; a += hop) {
      final c = BpmKeyDetector.bpmFromEnvelope(env.slice(a, a + win));
      beat.add(c.isNotEmpty && c.first.score >= beatScoreThreshold);
    }
    // 拍のある窓が 2 つ続く最初と最後（1 つだけ飛び出た窓はトークの中の偶然として無視）
    var first = -1, last = -1;
    for (var i = 0; i + 1 < beat.length; i++) {
      if (beat[i] && beat[i + 1]) {
        if (first < 0) first = i;
        last = i + 1;
      }
    }
    if (first < 0) return MusicSpan.notMusic;
    var beats = 0;
    for (var i = first; i <= last; i++) {
      if (beat[i]) beats++;
    }
    final coarseStart = first * hop, coarseEnd = min(n, last * hop + win);
    if ((coarseEnd - coarseStart) / fps < _minMusicSec ||
        beats / (last - first + 1) < _minBeatRatio) {
      return MusicSpan.notMusic;
    }

    // 範囲の中で拍の格子を求め、境目の前後をブロックで確かめる
    final span = env.slice(coarseStart, coarseEnd);
    final bpms = BpmKeyDetector.bpmFromEnvelope(span);
    final grid = bpms.isEmpty ? null : BpmKeyDetector.detectBeatGrid(span, bpms.first.bpm);
    var startFrame = coarseStart, endFrame = coarseEnd;
    if (grid != null) {
      final onset = BpmKeyDetector.weightedOnset(env);
      final block = (_blockSec * fps).round(), step = fps.round();
      bool locked(int i) =>
          i >= 0 &&
          i + block <= n &&
          BpmKeyDetector.gridLock(env, onset, grid, i, i + block) >= lockThreshold;
      final margin = (_windowSec * fps).round();
      // 始まり: 粗い境目の前後で、そこから 3 ブロック続けて拍に乗る最初のブロックの中央
      if (coarseStart > 0) {
        for (var i = max(0, coarseStart - margin); i <= coarseStart + margin; i += step) {
          if (locked(i) && locked(i + step) && locked(i + step * 2)) {
            startFrame = i + block ~/ 2;
            break;
          }
        }
      }
      // 終わり: 同じく、そこまで 3 ブロック続けて拍に乗る最後のブロックの中央
      if (coarseEnd < n) {
        for (var i = min(n - block, coarseEnd - block + margin ~/ 2);
            i >= coarseEnd - block - margin;
            i -= step) {
          if (locked(i) && locked(i - step) && locked(i - step * 2)) {
            endFrame = i + block ~/ 2;
            break;
          }
        }
      }
    }
    // 粗い窓は曲の前後に窓 1 つ分はみ出すので、長さは詰めた後でもう一度確かめる
    if ((endFrame - startFrame) / fps < _minMusicSec) return MusicSpan.notMusic;
    final startMs = startFrame <= 0 ? 0 : env.timeMs(startFrame.toDouble()).round();
    return MusicSpan(
      isMusic: true,
      startMs: startMs,
      endMs: endFrame >= n ? null : env.timeMs(endFrame.toDouble()).round(),
    );
  }
}
