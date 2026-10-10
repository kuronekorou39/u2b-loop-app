import 'dart:math';
import 'dart:typed_data';

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
  const AudioAnalysisResult({required this.bpmCandidates, required this.keyCandidates});
  final List<BpmCandidate> bpmCandidates;
  final List<KeyCandidate> keyCandidates;

  double? get bpm => bpmCandidates.isEmpty ? null : bpmCandidates.first.bpm;
  String? get key => keyCandidates.isEmpty ? null : keyCandidates.first.key;
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
    return AudioAnalysisResult(
      bpmCandidates: detectBpm(pcm, sampleRate),
      keyCandidates: detectKey(pcm, sampleRate),
    );
  }

  /// スペクトラルフラックスの自己相関でテンポを求める。
  /// 戻り値はスコア降順で最大3件。短すぎる入力は空。
  static List<BpmCandidate> detectBpm(Int16List pcm, int sampleRate) {
    const win = 512, hop = 128;
    if (pcm.length < win * 4) return const [];
    final nFrames = 1 + (pcm.length - win) ~/ hop;
    final fft = _Fft(win);
    final w = _hann(win);
    final nb = win ~/ 2 + 1;
    final re = Float64List(win), im = Float64List(win);
    var prev = Float64List(nb), cur = Float64List(nb);
    final flux = Float64List(nFrames - 1);

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
        var s = 0.0;
        for (var k = 0; k < nb; k++) {
          final d = cur[k] - prev[k];
          if (d > 0) s += d;
        }
        flux[f - 1] = s;
      }
      final t = prev;
      prev = cur;
      cur = t;
    }

    // 1秒の移動平均を引いて音量の起伏を除く
    final fps = sampleRate / hop;
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
