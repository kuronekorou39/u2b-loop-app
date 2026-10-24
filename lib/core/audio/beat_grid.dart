/// 拍の線の材料: 拍の格子と、小節頭の代わりの基準（ドロップ。解析の小節頭が確かなら使わない）
typedef BeatLineSource = ({BeatGrid grid, double? anchorMs});

/// 曲の拍の格子（精密な BPM と最初の拍の位置）。
///
/// 解析で求めた BPM は 0.1 刻みで、4 分間では拍の半分ほどズレが積もるので、
/// 拍合わせには別に精密な値を持つ。テンポが一定（打ち込み・DJ 向きの曲）を前提にした
/// 等間隔の格子で、生演奏の揺れには追従しない。
class BeatGrid {
  const BeatGrid({
    required this.bpm,
    required this.offsetMs,
    this.confidence = 1,
    this.downbeatMs,
    this.downbeatConfidence,
  });

  /// 精密な BPM（0.01% 程度）
  final double bpm;

  /// 最初の拍の位置（ミリ秒、0 ≤ offset < 1 拍）
  final double offsetMs;

  /// 格子の当てはまり（0〜1）。等間隔の格子に立ち上がりがどれだけ乗っているか
  /// （櫛形フィルタの最良スコアに対する、位相をずらしたときの平均スコアの比から）。
  /// 打ち込みの曲は高く、生演奏・揺れる曲は低い。[minConfidence] 未満なら拍合わせをしない
  final double confidence;

  /// これ未満の格子は信用しない（拍合わせ・テンポ合わせを自動で切る）
  static const minConfidence = 0.25;

  bool get reliable => confidence >= minConfidence;

  /// 解析で求めた小節頭（1 拍目の拍の頭、ミリ秒）。null = 未解析（v1.106 以前）・推定できない
  final double? downbeatMs;

  /// 小節頭の推定の確かさ（0〜1、[Downbeat.confidence]）
  final double? downbeatConfidence;

  /// これ以上なら解析の小節頭を使う。未満ならドロップなどの基準点から数える
  static const minDownbeatConfidence = 0.5;

  bool get hasDownbeat =>
      downbeatMs != null && (downbeatConfidence ?? 0) >= minDownbeatConfidence;

  /// 1 小節の拍数（4 拍子だけを扱う）
  static const beatsPerBar = 4;

  /// 小節頭の基準: 解析の小節頭が確かならそれ、無ければ [fallbackMs]（ドロップなど）、
  /// それも無ければ最初の拍
  double barAnchorMs([double? fallbackMs]) =>
      hasDownbeat ? downbeatMs! : (fallbackMs ?? offsetMs);

  /// 小節の格子: [barAnchorMs] に最も近い拍の頭を小節頭として 4 拍ごとに並べた格子
  BeatGrid barGrid([double? anchorMs]) =>
      _grouped(beatsPerBar, barAnchorMs(anchorMs));

  /// 1 フレーズの小節数（8 小節 = 32 拍）。曲の段落（A メロ・サビ・ドロップ）はこの単位で変わる
  static const barsPerPhrase = 8;

  /// フレーズの格子: [dropMs]（ドロップ = 段落の頭）に最も近い小節頭をフレーズの頭として
  /// 8 小節ごとに並べた格子。小節頭は [barGrid] と同じ基準。
  /// ドロップが無ければ小節頭の基準から数える（イントロの長さ次第で外れやすい）
  BeatGrid phraseGrid([double? dropMs]) {
    final bars = barGrid(dropMs);
    return bars._grouped(barsPerPhrase, dropMs ?? bars.offsetMs);
  }

  /// [beats] 拍ごとの格子。[anchorMs] に最も近い拍の頭をかたまりの頭にする
  BeatGrid _grouped(int beats, double anchorMs) {
    final groupMs = periodMs * beats;
    final anchorBeat = ((anchorMs - offsetMs) / periodMs).round();
    final off = (offsetMs + anchorBeat * periodMs) % groupMs;
    return BeatGrid(
        bpm: bpm / beats,
        offsetMs: off < 0 ? off + groupMs : off,
        confidence: confidence);
  }

  /// 小節頭を足したもの（解析の結果を格子に載せる）
  BeatGrid withDownbeat(Downbeat? downbeat) {
    return BeatGrid(
        bpm: bpm,
        offsetMs: offsetMs,
        confidence: confidence,
        downbeatMs: downbeat?.ms,
        downbeatConfidence: downbeat?.confidence);
  }

  /// [startMs]〜[endMs] にある拍の頭と、小節の何拍目か（1〜[beatsPerBar]）。
  /// 何拍目かは [barGrid] と同じ基準（[barAnchorMs]）で数える。拍の線の表示用
  Iterable<({double ms, int number})> beatsBetween(double startMs, double endMs,
      {double? anchorMs}) sync* {
    final period = periodMs;
    if (period <= 0 || endMs < startMs) return;
    final anchorBeat = ((barAnchorMs(anchorMs) - offsetMs) / period).round();
    for (var k = ((startMs - offsetMs) / period).ceil();; k++) {
      final ms = offsetMs + k * period;
      if (ms > endMs) return;
      final i = (k - anchorBeat) % beatsPerBar;
      yield (ms: ms, number: (i < 0 ? i + beatsPerBar : i) + 1);
    }
  }

  /// 位置 [ms] 以前で最も近い拍の頭（媒体のミリ秒）
  double floorBeatMs(double ms) => ms - phaseAt(ms) * periodMs;

  /// 1 拍の長さ（媒体のミリ秒）
  double get periodMs => 60000 / bpm;

  /// 位置 [ms] の拍の中の位相（0 = 拍の頭、1 に近いほど次の拍の直前）
  double phaseAt(double ms) {
    final p = ((ms - offsetMs) / periodMs) % 1;
    return p < 0 ? p + 1 : p;
  }

  /// 位置 [ms] から次の拍の頭までの長さ（媒体のミリ秒）。拍の頭ちょうどなら 0
  double toNextBeatMs(double ms) {
    final p = phaseAt(ms);
    return p == 0 ? 0 : (1 - p) * periodMs;
  }

  @override
  String toString() => 'BeatGrid(${bpm.toStringAsFixed(2)} BPM, '
      'offset ${offsetMs.toStringAsFixed(0)}ms, '
      'confidence ${confidence.toStringAsFixed(2)}'
      '${downbeatMs == null ? '' : ', 1拍目 ${downbeatMs!.toStringAsFixed(0)}ms '
          '(${downbeatConfidence?.toStringAsFixed(2)})'})';
}

/// 小節頭（1 拍目）の推定
class Downbeat {
  const Downbeat({required this.ms, required this.confidence});

  /// 1 拍目の拍の頭（ミリ秒）。曲の中のどれか 1 つ（ふつうは最初の小節頭）
  final double ms;

  /// 曲を 8 小節ごとに区切って推定し直したとき、同じ答えになった区間の割合（0〜1）
  final double confidence;

  @override
  String toString() =>
      'Downbeat(${ms.toStringAsFixed(0)}ms, ${confidence.toStringAsFixed(2)})';
}

/// 2 曲の拍を合わせる計算（純粋関数。PlaylistEngine から使う）。
///
/// 1. 交差を始める前に、入る曲の開始位置を ±半拍の範囲でずらして拍の頭を揃える
///    （[alignedStartMs]）。
/// 2. 鳴り始めてからは両プレイヤーの再生位置から位相のずれを測り（[phaseErrorMs]）、
///    入る曲の速度を少しだけ変えて寄せる（[rateAdjust]）。DJ がプラッターを押す／引く動きで、
///    play() の開始遅延や、シークの誤差はここで吸収する。
class BeatMatcher {
  BeatMatcher._();

  /// ナッジの速度変化の上限（±比率）。これ以上は音程補正が目立つ
  static const maxRateAdjust = 0.03;

  /// 位相誤差をこの時間で消す速さにする（ms）。短いほど強く、長いほど穏やか
  static const correctionWindowMs = 2500.0;

  /// この誤差より小さければ合っているとみなして速度を戻す（ms）
  static const lockToleranceMs = 6.0;

  /// 入る曲の開始位置を、出る曲の拍の頭に合うようずらす。
  ///
  /// [outPosMs] は出る曲の交差開始位置、[inStartMs] は入る曲の予定開始位置（どちらも媒体 ms）。
  /// [outRate] / [inRate] はそれぞれの再生速度（実時間に直すため）。
  /// 戻り値は調整後の開始位置。ずらす量は ±半拍以内
  static double alignedStartMs({
    required BeatGrid out,
    required BeatGrid in_,
    required double outPosMs,
    required double outRate,
    required double inStartMs,
    required double inRate,
  }) {
    // 出る曲の次の拍までの実時間
    final tOutRt = out.toNextBeatMs(outPosMs) / outRate;
    // 入る曲は、開始位置からその実時間後に拍の頭が来る位相にしたい
    final target = _frac(1 - tOutRt * inRate / in_.periodMs);
    final current = in_.phaseAt(inStartMs);
    var deltaBeats = _frac(target - current);
    if (deltaBeats > 0.5) deltaBeats -= 1;
    return inStartMs + deltaBeats * in_.periodMs;
  }

  /// 交差中の位相誤差（実時間 ms）。正なら入る曲の拍が遅れている（速める方向）。
  /// 入る曲の 1 拍の実時間で折り返すので、戻り値は ±半拍以内
  static double phaseErrorMs({
    required BeatGrid out,
    required BeatGrid in_,
    required double outPosMs,
    required double outRate,
    required double inPosMs,
    required double inRate,
  }) {
    final tOut = out.toNextBeatMs(outPosMs) / outRate;
    final tIn = in_.toNextBeatMs(inPosMs) / inRate;
    final period = in_.periodMs / inRate;
    var err = (tIn - tOut) % period;
    if (err < 0) err += period;
    if (err > period / 2) err -= period;
    return err;
  }

  /// 位相誤差 [errMs] に対する速度の変化（比率）。許容内なら 0
  static double rateAdjust(double errMs) {
    if (errMs.abs() < lockToleranceMs) return 0;
    return (errMs / correctionWindowMs).clamp(-maxRateAdjust, maxRateAdjust);
  }

  static double _frac(double x) {
    final f = x % 1;
    return f < 0 ? f + 1 : f;
  }
}
