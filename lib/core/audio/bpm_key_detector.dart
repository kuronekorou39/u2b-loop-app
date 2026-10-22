import 'dart:math';
import 'dart:typed_data';

import 'beat_grid.dart';
import 'musical_key.dart';

/// BPM 候補（スコア降順で上位数件）
class BpmCandidate {
  const BpmCandidate(this.bpm, this.score);
  final double bpm;

  /// 正規化自己相関 × テンポ事前分布。1位/2位の比が小さいほど倍/半分の曖昧さが大きい
  final double score;
}

/// キー候補（相関降順で上位数件）
class KeyCandidate {
  const KeyCandidate(this.key, this.correlation);

  /// 'Gmin' / 'A#maj' 形式（[MusicalKey.allKeys] のいずれか）
  final String key;
  final double correlation;
}

class AudioAnalysisResult {
  const AudioAnalysisResult({
    required this.bpmCandidates,
    required this.keyCandidates,
    this.beatGrid,
  });
  final List<BpmCandidate> bpmCandidates;
  final List<KeyCandidate> keyCandidates;

  /// 1 位の BPM で求めた拍の格子と小節頭（BPM が無ければ null）
  final BeatGrid? beatGrid;

  double? get bpm => bpmCandidates.isEmpty ? null : bpmCandidates.first.bpm;
  String? get key => keyCandidates.isEmpty ? null : keyCandidates.first.key;
}

/// 立ち上がりの強さの時系列（スペクトラルフラックス）。
/// [full] は全帯域、[low] は 250Hz 以下（キック）。どちらも 1 秒の移動平均を引いてある
class OnsetEnvelope {
  const OnsetEnvelope({required this.full, required this.low, required this.fps, required this.frameOffsetMs});
  final Float64List full;
  final Float64List low;

  /// 1 秒あたりのフレーム数
  final double fps;

  /// フレーム i の立ち上がりが曲のどの時刻か: (i + 1) / fps * 1000 + frameOffsetMs
  final double frameOffsetMs;

  double timeMs(double frame) => (frame + 1) / fps * 1000 + frameOffsetMs;
}

/// BPM とキーをモノラル PCM から検出する（純Dart・副作用なし）。
///
/// 重い処理なので呼び出し側で isolate に載せること。
/// 2026-10 の検証では 11025Hz・4分の曲で PC 0.25秒、ジャズ13曲で
/// BPM は倍/半分を含めて librosa と 10/13 一致、キーは 13/13 が Camelot 互換だった。
class BpmKeyDetector {
  BpmKeyDetector._();

  /// ネイティブ側がこのレートに間引いて渡してくる
  static const analysisSampleRate = 11025;

  // Krumhansl-Schmuckler キープロファイル（C を起点に 12 半音）
  static const _major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
  static const _minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

  static AudioAnalysisResult analyze(Int16List pcm, int sampleRate) {
    final env = onsetEnvelope(pcm, sampleRate);
    final bpms = env == null ? const <BpmCandidate>[] : bpmFromEnvelope(env);
    return AudioAnalysisResult(
      bpmCandidates: bpms,
      keyCandidates: detectKey(pcm, sampleRate),
      beatGrid: env == null || bpms.isEmpty
          ? null
          : _gridWithDownbeat(pcm, sampleRate, env, bpms.first.bpm),
    );
  }

  /// 拍の格子に小節頭を載せたもの
  static BeatGrid? _gridWithDownbeat(
      Int16List pcm, int sampleRate, OnsetEnvelope env, double bpm) {
    final grid = detectBeatGrid(env, bpm);
    if (grid == null) return null;
    return grid.withDownbeat(detectDownbeat(pcm, sampleRate, grid));
  }

  /// スペクトラルフラックスの自己相関でテンポを求める。
  /// 戻り値はスコア降順で最大3件。短すぎる入力は空。
  static List<BpmCandidate> detectBpm(Int16List pcm, int sampleRate) {
    final env = onsetEnvelope(pcm, sampleRate);
    return env == null ? const [] : bpmFromEnvelope(env);
  }

  /// 立ち上がりの時系列を求める（BPM と拍の格子の共通の材料）。短すぎる入力は null
  static OnsetEnvelope? onsetEnvelope(Int16List pcm, int sampleRate) {
    const win = 512, hop = 128;
    if (pcm.length < win * 4) return null;
    final nFrames = 1 + (pcm.length - win) ~/ hop;
    final fft = _Fft(win);
    final w = _hann(win);
    final nb = win ~/ 2 + 1;
    // 250Hz 以下の bin（キック・ベースの立ち上がり）
    final nbLow = min(nb, (250 * win / sampleRate).floor() + 1);
    final re = Float64List(win), im = Float64List(win);
    var prev = Float64List(nb), cur = Float64List(nb);
    final flux = Float64List(nFrames - 1);
    final fluxLow = Float64List(nFrames - 1);

    for (var f = 0; f < nFrames; f++) {
      final base = f * hop;
      for (var i = 0; i < win; i++) {
        re[i] = pcm[base + i] / 32768.0 * w[i];
        im[i] = 0;
      }
      fft.transform(re, im);
      for (var k = 0; k < nb; k++) {
        cur[k] = log(1 + 100 * sqrt(re[k] * re[k] + im[k] * im[k]));
      }
      if (f > 0) {
        var s = 0.0, sl = 0.0;
        for (var k = 0; k < nb; k++) {
          final d = cur[k] - prev[k];
          if (d > 0) {
            s += d;
            if (k < nbLow) sl += d;
          }
        }
        flux[f - 1] = s;
        fluxLow[f - 1] = sl;
      }
      final t = prev;
      prev = cur;
      cur = t;
    }

    final fps = sampleRate / hop;
    return OnsetEnvelope(
      full: _detrend(flux, fps),
      low: _detrend(fluxLow, fps),
      fps: fps,
      // flux[i] は frame i+1 と frame i の差。窓の中央に立ち上がりが来たときが最大。
      // クリック音で測ると、それでもまだ 10ms ほど早く出る（70〜174 BPM で一定）ので足す
      frameOffsetMs: win / 2 / sampleRate * 1000 + 10,
    );
  }

  /// 1秒の移動平均を引いて音量の起伏を除く
  static Float64List _detrend(Float64List flux, double fps) {
    final k = fps.toInt();
    final n = flux.length;
    final det = Float64List(n);
    final cum = Float64List(n + 1);
    for (var i = 0; i < n; i++) {
      cum[i + 1] = cum[i] + flux[i];
    }
    for (var i = 0; i < n; i++) {
      final lo = max(0, i - k ~/ 2), hi = min(n, i - k ~/ 2 + k);
      det[i] = flux[i] - (cum[hi] - cum[lo]) / k;
    }
    return det;
  }

  /// 立ち上がりの自己相関からテンポ候補を求める
  static List<BpmCandidate> bpmFromEnvelope(OnsetEnvelope env) {
    final det = env.full;
    final fps = env.fps;
    final n = det.length;

    // 55〜220 BPM に相当するラグだけ自己相関を直接計算
    final lagMin = (fps * 60 / 220).toInt(), lagMax = (fps * 60 / 55).toInt();
    var ac0 = 0.0;
    for (var i = 0; i < n; i++) {
      ac0 += det[i] * det[i];
    }
    if (ac0 <= 0) return const [];
    final count = lagMax - lagMin + 1;
    final score = Float64List(count);
    final bpms = Float64List(count);
    for (var lag = lagMin; lag <= lagMax; lag++) {
      var s = 0.0;
      for (var i = 0; i + lag < n; i++) {
        s += det[i] * det[i + lag];
      }
      final bpm = 60 * fps / lag;
      // 120 BPM を中心に 1 オクターブ幅の対数ガウス事前分布（極端な倍/半分を抑える）
      final lg = log(bpm / 120) / ln2;
      score[lag - lagMin] = s / ac0 * exp(-0.5 * lg * lg);
      bpms[lag - lagMin] = bpm;
    }
    final peaks = <int>[];
    for (var i = 1; i < count - 1; i++) {
      if (score[i] >= score[i - 1] && score[i] >= score[i + 1]) peaks.add(i);
    }
    peaks.sort((a, b) => score[b].compareTo(score[a]));
    return [
      for (final i in peaks.take(3))
        BpmCandidate((bpms[i] * 10).round() / 10, score[i]),
    ];
  }

  /// 拍の格子を求める。
  ///
  /// 自己相関のラグは整数フレームなので BPM の分解能は 2% ほどしかなく、位相を曲全体で
  /// 合わせるには足りない。[bpm] の周りで周期を細かく振り、各周期で位相を 0.5 フレーム刻みで
  /// 動かし、格子の上の立ち上がりの合計（櫛形フィルタ）が最大になる組を選ぶ。
  /// 立ち上がりは低域を 2 倍に重みづけして、裏拍のハイハットより表拍のキックに寄せる。
  /// 短すぎる（4 秒未満）か [bpm] が不正なら null
  static BeatGrid? detectBeatGrid(OnsetEnvelope env, double bpm) {
    final n = env.full.length;
    final fps = env.fps;
    if (bpm <= 0 || n < fps * 4) return null;

    // 低域を強めた立ち上がり（それぞれ RMS で揃えてから足す）
    final rmsFull = _rms(env.full), rmsLow = _rms(env.low);
    if (rmsFull <= 0) return null;
    final onset = Float64List(n);
    for (var i = 0; i < n; i++) {
      onset[i] = env.full[i] / rmsFull +
          (rmsLow > 0 ? 2 * env.low[i] / rmsLow : 0);
    }

    double comb(double period, double phase) {
      var s = 0.0;
      for (var x = phase; x < n - 1; x += period) {
        final i = x.floor();
        final f = x - i;
        s += onset[i] * (1 - f) + onset[i + 1] * f;
      }
      return s;
    }

    var bestBpm = bpm, bestPhase = 0.0, bestScore = double.negativeInfinity;
    void search(double center, double spanRatio, double stepRatio) {
      final steps = (spanRatio / stepRatio).round();
      for (var k = -steps; k <= steps; k++) {
        final b = center * (1 + k * stepRatio);
        final period = 60 * fps / b;
        for (var phase = 0.0; phase < period; phase += 0.5) {
          final s = comb(period, phase);
          if (s > bestScore) {
            bestScore = s;
            bestBpm = b;
            bestPhase = phase;
          }
        }
      }
    }

    // 粗く ±1.5% を 0.1% 刻み → その周りを ±0.1% を 0.005% 刻み
    search(bpm, 0.015, 0.001);
    search(bestBpm, 0.001, 0.00005);

    // 信頼度: 周期を 10〜20% ずらした格子でも同じくらいのスコアが出るなら、
    // 立ち上がりが等間隔に並んでいない（生演奏・揺れる曲・拍の無い音）
    final bestPeriod = 60 * fps / bestBpm;
    var wrong = 0.0;
    for (final ratio in const [0.8, 0.85, 0.9, 1.1, 1.15, 1.2, 1.25]) {
      final period = bestPeriod * ratio;
      for (var phase = 0.0; phase < period; phase += 0.5) {
        final s = comb(period, phase);
        if (s > wrong) wrong = s;
      }
    }
    final confidence =
        bestScore <= 0 ? 0.0 : (1 - wrong / bestScore).clamp(0.0, 1.0);

    final period = 60000 / bestBpm;
    return BeatGrid(
        bpm: bestBpm,
        offsetMs: env.timeMs(bestPhase) % period,
        confidence: confidence);
  }

  static double _rms(Float64List v) {
    if (v.isEmpty) return 0;
    var s = 0.0;
    for (final x in v) {
      s += x * x;
    }
    return sqrt(s / v.length);
  }

  /// 小節頭（4 拍の「1」）を推定する。[grid] の拍のうち、どれが 1 拍目かを 4 通り比べる。
  ///
  /// 手がかりは和音の変わり目: 拍ごとのクロマ（12 音の強さ）の、前 2 拍と後 2 拍の違い。
  /// コードは小節の頭で変わることが多い。2026-10 に beat_this（学習済みの拍・小節頭検出）の
  /// 答えと 10 曲で比べて 8 曲一致。低音の立ち上がり（キック）も試したが、4 つ打ちでは
  /// どの拍にも入るので 2 曲しか合わず、混ぜても良くならなかった。
  ///
  /// 信頼度は、曲を 8 小節ごとに区切ってそれぞれで推定し、全体の答えと一致した区間の割合。
  /// 拍の格子が無い・短すぎる（8 小節未満）なら null
  static Downbeat? detectDownbeat(Int16List pcm, int sampleRate, BeatGrid grid) {
    final period = grid.periodMs;
    final durationMs = pcm.length / sampleRate * 1000;
    final beats = <double>[
      for (var t = grid.offsetMs; t + period <= durationMs; t += period) t,
    ];
    const perBar = BeatGrid.beatsPerBar;
    if (beats.length < perBar * 8) return null;

    final chroma = _beatChroma(pcm, sampleRate, beats, period);
    final n = beats.length;

    // 和音の変わり目（前 2 拍と後 2 拍のクロマの違い）
    const context = 2;
    final change = Float64List(n);
    for (var k = context; k + context <= n; k++) {
      final before = Float64List(12), after = Float64List(12);
      for (var j = 0; j < context; j++) {
        for (var i = 0; i < 12; i++) {
          before[i] += chroma[k - 1 - j][i];
          after[i] += chroma[k + j][i];
        }
      }
      change[k] = 1 - _cosine(before, after);
    }

    int bestPhase(int from, int to) {
      final sum = Float64List(perBar), count = Int32List(perBar);
      for (var k = from; k < to; k++) {
        sum[k % perBar] += change[k];
        count[k % perBar]++;
      }
      var best = 0;
      for (var p = 1; p < perBar; p++) {
        if (sum[p] / max(1, count[p]) > sum[best] / max(1, count[best])) best = p;
      }
      return best;
    }

    final phase = bestPhase(0, n);
    const section = perBar * 8;
    var sections = 0, agree = 0;
    for (var from = 0; from + section <= n; from += section) {
      sections++;
      if (bestPhase(from, from + section) == phase) agree++;
    }
    return Downbeat(
      ms: beats[phase],
      confidence: sections == 0 ? 0 : agree / sections,
    );
  }

  /// 拍ごとのクロマ（各拍の区間のフレームを平均し、長さ 1 に揃えたもの）
  static List<Float64List> _beatChroma(
      Int16List pcm, int sampleRate, List<double> beats, double periodMs) {
    const win = 2048, hop = 512;
    final fft = _Fft(win);
    final w = _hann(win);
    final nb = win ~/ 2 + 1;
    final pc = Int32List(nb);
    for (var k = 0; k < nb; k++) {
      final f = k * sampleRate / win;
      pc[k] = (f >= 55 && f <= 2000)
          ? ((12 * log(f / 440) / ln2).round() + 9) % 12
          : -1;
    }
    final re = Float64List(win), im = Float64List(win);
    final out = List.generate(beats.length, (_) => Float64List(12));
    final nFrames = 1 + (pcm.length - win) ~/ hop;
    var beat = 0;
    for (var fr = 0; fr < nFrames; fr++) {
      final base = fr * hop;
      final centerMs = (base + win / 2) / sampleRate * 1000;
      while (beat < beats.length && centerMs >= beats[beat] + periodMs) {
        beat++;
      }
      if (beat >= beats.length) break;
      if (centerMs < beats[beat]) continue;
      for (var i = 0; i < win; i++) {
        re[i] = pcm[base + i] / 32768.0 * w[i];
        im[i] = 0;
      }
      fft.transform(re, im);
      final c = out[beat];
      for (var k = 0; k < nb; k++) {
        final p = pc[k];
        if (p < 0) continue;
        c[p] += log(1 + 100 * sqrt(re[k] * re[k] + im[k] * im[k]));
      }
    }
    for (final c in out) {
      var s = 0.0;
      for (final v in c) {
        s += v * v;
      }
      final norm = sqrt(s);
      if (norm > 0) {
        for (var i = 0; i < 12; i++) {
          c[i] /= norm;
        }
      }
    }
    return out;
  }

  static double _cosine(List<double> a, List<double> b) {
    var ab = 0.0, aa = 0.0, bb = 0.0;
    for (var i = 0; i < a.length; i++) {
      ab += a[i] * b[i];
      aa += a[i] * a[i];
      bb += b[i] * b[i];
    }
    return aa == 0 || bb == 0 ? 1 : ab / sqrt(aa * bb);
  }

  /// 12音階クロマと Krumhansl-Schmuckler プロファイルの相関でキーを求める。
  /// 戻り値は相関降順で最大3件。短すぎる入力は空。
  static List<KeyCandidate> detectKey(Int16List pcm, int sampleRate) {
    const win = 4096, hop = 2048;
    if (pcm.length < win * 2) return const [];
    final nFrames = 1 + (pcm.length - win) ~/ hop;
    final fft = _Fft(win);
    final w = _hann(win);
    final nb = win ~/ 2 + 1;
    final re = Float64List(win), im = Float64List(win);
    // bin → ピッチクラス（C=0）。55〜2000Hz の外は -1
    final pc = Int32List(nb);
    for (var k = 0; k < nb; k++) {
      final f = k * sampleRate / win;
      pc[k] = (f >= 55 && f <= 2000)
          ? ((12 * log(f / 440) / ln2).round() + 9) % 12
          : -1;
    }
    final chroma = Float64List(12);
    for (var fr = 0; fr < nFrames; fr++) {
      final base = fr * hop;
      for (var i = 0; i < win; i++) {
        re[i] = pcm[base + i] / 32768.0 * w[i];
        im[i] = 0;
      }
      fft.transform(re, im);
      for (var k = 0; k < nb; k++) {
        final p = pc[k];
        if (p < 0) continue;
        chroma[p] += log(1 + 100 * sqrt(re[k] * re[k] + im[k] * im[k]));
      }
    }
    return keyFromChroma(chroma);
  }

  /// クロマ（C 起点 12 要素）からキー候補を求める
  static List<KeyCandidate> keyFromChroma(List<double> chroma) {
    if (chroma.every((v) => v == 0)) return const [];
    final out = <KeyCandidate>[];
    for (var tonic = 0; tonic < 12; tonic++) {
      for (final (mode, prof) in [(KeyMode.major, _major), (KeyMode.minor, _minor)]) {
        final rolled = List.generate(12, (i) => prof[(i - tonic + 12) % 12]);
        final r = _pearson(chroma, rolled);
        if (r.isNaN) continue;
        out.add(KeyCandidate(MusicalKey.name(tonic, mode), r));
      }
    }
    out.sort((a, b) => b.correlation.compareTo(a.correlation));
    return out.take(3).toList();
  }

  static double _pearson(List<double> a, List<double> b) {
    final n = a.length;
    final ma = a.reduce((x, y) => x + y) / n, mb = b.reduce((x, y) => x + y) / n;
    var sab = 0.0, saa = 0.0, sbb = 0.0;
    for (var i = 0; i < n; i++) {
      sab += (a[i] - ma) * (b[i] - mb);
      saa += (a[i] - ma) * (a[i] - ma);
      sbb += (b[i] - mb) * (b[i] - mb);
    }
    return sab / sqrt(saa * sbb);
  }

  static Float64List _hann(int n) => Float64List.fromList(
      List.generate(n, (i) => 0.5 - 0.5 * cos(2 * pi * i / (n - 1))));
}

/// 基数2の反復FFT（in-place）。[n] は2の冪であること
class _Fft {
  _Fft(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Uint32List(n) {
    for (var k = 0; k < n ~/ 2; k++) {
      _cos[k] = cos(2 * pi * k / n);
      _sin[k] = sin(2 * pi * k / n);
    }
    final bits = (log(n) / ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }
  final int n;
  final Float64List _cos, _sin;
  final Uint32List _rev;

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step];
          final wi = -_sin[k * step];
          final a = start + k;
          final b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }
}
