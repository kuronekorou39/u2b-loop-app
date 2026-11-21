import 'dart:math';
import 'dart:typed_data';

import 'fft.dart';

/// 帯域ごとの立ち上がりの時系列（フレーム × [bands]）。どの音色がいつ鳴り始めたかの並びで、
/// 同じフレーズが戻ってくるかを見るのに使う。1 秒の移動平均を帯域ごとに引いてある
class BandFlux {
  BandFlux._(this._data, this.frames, this.fps);

  final Float32List _data;

  /// フレーム数
  final int frames;

  /// 1 秒あたりのフレーム数
  final double fps;

  /// 帯域の区切り（Hz）: 低いほうはキック・ベース、中はスネア・歌、高はハイハット
  static const edges = [0, 120, 250, 400, 650, 1000, 1500, 2200, 3200, 4500, 5513];
  static const bands = 10;

  static const _win = 512, _hop = 128;

  /// 短すぎる入力は null
  static BandFlux? of(Int16List pcm, int sampleRate) {
    if (pcm.length < _win * 4) return null;
    final frames = 1 + (pcm.length - _win) ~/ _hop;
    final fft = Fft(_win);
    final w = Float64List.fromList(
        List.generate(_win, (i) => 0.5 - 0.5 * cos(2 * pi * i / (_win - 1))));
    final nb = _win ~/ 2 + 1;
    final bandOf = Int32List(nb);
    final binCount = Int32List(bands);
    for (var k = 0; k < nb; k++) {
      final f = k * sampleRate / _win;
      var b = -1;
      for (var j = 0; j < bands; j++) {
        if (f >= edges[j] && f < edges[j + 1]) b = j;
      }
      bandOf[k] = b;
      if (b >= 0) binCount[b]++;
    }
    final re = Float64List(_win), im = Float64List(_win);
    var prev = Float64List(bands), cur = Float64List(bands);
    final flux = Float32List(frames * bands);
    for (var f = 0; f < frames; f++) {
      final base = f * _hop;
      for (var i = 0; i < _win; i++) {
        re[i] = pcm[base + i] / 32768.0 * w[i];
        im[i] = 0;
      }
      fft.transform(re, im);
      cur.fillRange(0, bands, 0);
      for (var k = 0; k < nb; k++) {
        final b = bandOf[k];
        if (b >= 0) cur[b] += log(1 + 100 * sqrt(re[k] * re[k] + im[k] * im[k]));
      }
      for (var b = 0; b < bands; b++) {
        if (binCount[b] > 0) cur[b] /= binCount[b];
        if (f > 0) {
          final d = cur[b] - prev[b];
          flux[f * bands + b] = d > 0 ? d : 0;
        }
      }
      final t = prev;
      prev = cur;
      cur = t;
    }
    final fps = sampleRate / _hop;
    _detrend(flux, frames, fps.toInt());
    return BandFlux._(flux, frames, fps);
  }

  /// 帯域ごとに [k] フレームの移動平均を引く（音量の起伏を除く）
  static void _detrend(Float32List flux, int frames, int k) {
    final cum = Float64List(frames + 1);
    final out = Float64List(frames);
    for (var b = 0; b < bands; b++) {
      for (var i = 0; i < frames; i++) {
        cum[i + 1] = cum[i] + flux[i * bands + b];
      }
      for (var i = 0; i < frames; i++) {
        final lo = max(0, i - k ~/ 2), hi = min(frames, lo + k);
        out[i] = flux[i * bands + b] - (cum[hi] - cum[lo]) / (hi - lo);
      }
      for (var i = 0; i < frames; i++) {
        flux[i * bands + b] = out[i];
      }
    }
  }

  /// フレーム [from]〜[to] の中で、[lag] フレーム離れた所と音の並びがどれだけ同じか（−1〜1）
  double selfSimilarity(int from, int to, int lag) {
    final end = min(to, frames);
    if (lag <= 0 || end - from <= lag + 8) return 0;
    var ab = 0.0, aa = 0.0, bb = 0.0;
    for (var i = from * bands; i < (end - lag) * bands; i++) {
      final x = _data[i], y = _data[i + lag * bands];
      ab += x * y;
      aa += x * x;
      bb += y * y;
    }
    return aa <= 0 || bb <= 0 ? 0 : ab / sqrt(aa * bb);
  }
}

/// テンポの取り違え（倍・半分・2:3）を直す（純 Dart・副作用なし）。
///
/// 立ち上がりの自己相関は、本当のテンポと 2:3 や倍/半分の周期を同じくらいに出す
/// （3 つずつまとまる刻みの曲や、ハーフタイムの曲）。そこで候補ごとに「その 4・8・16 拍後に
/// 同じ音の並びが戻ってくるか」を比べる。小節の長さが合っている候補ほどよく戻る。
/// 2026-11-21 に 51 曲を学習済みの拍検出と比べ、テンポの安定した曲で 9/12 → 12/12（倍/半分込み）
class TempoResolver {
  TempoResolver._();

  /// 候補にするテンポの範囲
  static const minBpm = 62.0, maxBpm = 200.0;

  /// 比べる拍数（1・2・4 小節）
  static const barBeats = [4, 8, 16];

  /// 2:3 系の候補（今のテンポに掛ける比）
  static const threeTwoRatios = [2 / 3, 3 / 4, 4 / 3, 3 / 2];

  /// 音の並びがこれより戻らない曲は判断の材料が無いので変えない
  static const minRepeat = 0.12;

  /// 2:3 系の候補へ移るのに必要な比（今のテンポより 1 割以上よく戻る）。
  /// 一定の刻みだけの音はどの候補も同じくらい戻るので、わずかな差では動かさない
  static const switchRatio = 1.1;

  /// 倍/半分の 2 つが「同じくらい戻る」とみなす差
  static const octaveMargin = 0.06;

  /// これより遅いテンポは、倍でも同じくらい戻り、半拍の所にも本当に刻みがあれば倍にする
  /// （ハーフタイムに聞こえる曲）
  static const slowBpm = 80.0;

  /// 倍にするのに必要な、倍のテンポの 1 拍後の戻り。本当に遅い曲は半拍後に戻らない
  /// （2026-11-21 の測定: 本当に倍の曲 0.09〜0.41、本当に遅い曲 −0.07〜0.06）
  static const minPulse = 0.08;

  /// 拍として聞きやすいテンポの範囲（2:3 系で移った先の倍/半分を選ぶとき）
  static const usualLow = 90.0, usualHigh = 180.0;

  static bool _inRange(double c) => c >= minBpm && c <= maxBpm;
  static bool _usual(double c) => c >= usualLow && c <= usualHigh;

  /// テンポ [c] の 1・2・4 小節あとに音の並びが戻る度合い（平均）
  static double barScore(BandFlux flux, int from, int to, double c) {
    final beat = 60 * flux.fps / c;
    var sum = 0.0;
    for (final n in barBeats) {
      sum += flux.selfSimilarity(from, to, (beat * n).round());
    }
    return sum / barBeats.length;
  }

  /// フレーム [from]〜[to] の曲のテンポを [bpm] から直す。直す理由が無ければ [bpm] のまま
  static double resolve(BandFlux flux, int from, int to, double bpm) => decide(
        bpm,
        bar: (c) => barScore(flux, from, to, c),
        pulse: (c) => flux.selfSimilarity(from, to, (60 * flux.fps / c).round()),
      );

  /// テンポを決める。[bar] は候補の 1・2・4 小節あとの戻り（[barScore]）、
  /// [pulse] は候補の 1 拍あとの戻り
  static double decide(
    double bpm, {
    required double Function(double c) bar,
    required double Function(double c) pulse,
  }) {
    if (bpm <= 0) return bpm;
    var chosen = bpm;
    var chosenScore = bar(bpm);
    double? best;
    var bestScore = double.negativeInfinity;
    for (final r in threeTwoRatios) {
      final c = bpm * r;
      if (!_inRange(c)) continue;
      final s = bar(c);
      if (s > bestScore) {
        best = c;
        bestScore = s;
      }
    }
    if (best != null && bestScore >= minRepeat && bestScore > chosenScore * switchRatio) {
      chosen = best;
      chosenScore = bestScore;
      // 移った先が遅すぎ・速すぎで、倍/半分も同じくらい戻るなら聞きやすい方へ
      if (!_usual(chosen)) {
        for (final f in const [2.0, 0.5]) {
          final c = chosen * f;
          if (!_inRange(c) || !_usual(c)) continue;
          final s = bar(c);
          if (s >= chosenScore - octaveMargin) {
            chosen = c;
            chosenScore = s;
            break;
          }
        }
      }
    }
    if (chosen < slowBpm &&
        chosen * 2 <= maxBpm &&
        chosenScore >= minRepeat &&
        bar(chosen * 2) >= chosenScore - octaveMargin &&
        pulse(chosen * 2) >= minPulse) {
      chosen *= 2;
    }
    return chosen;
  }
}
