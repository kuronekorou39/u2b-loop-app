import 'dart:math';

/// 曲の「ミックスイン点」と「ミックスアウト点」（ミリ秒）。
/// - [mixInMs]: 曲頭側で音量がぐっと上がる最初の点（ドロップ）。次曲として入るとき、
///   ここが切り替わりの瞬間に来るように開始位置をずらす
/// - [mixOutMs]: 曲末側で音量が落ち込んでそのまま終わりまで戻らない最初の点（アウトロの始まり）。
///   出ていく曲はここで切る
/// 見つからなければ null
class MixPoints {
  const MixPoints({this.mixInMs, this.mixOutMs});
  final int? mixInMs;
  final int? mixOutMs;

  static const none = MixPoints();

  @override
  bool operator ==(Object other) =>
      other is MixPoints && other.mixInMs == mixInMs && other.mixOutMs == mixOutMs;

  @override
  int get hashCode => Object.hash(mixInMs, mixOutMs);

  @override
  String toString() => 'MixPoints(in: $mixInMs, out: $mixOutMs)';
}

/// 波形（0〜1 に正規化した RMS 包絡、約 4000 点）からミックス点を求める（純Dart・副作用なし）。
///
/// DJ のつなぎでは、入る曲の静かなイントロを出る曲の終わりに重ね、入る曲の盛り上がり
/// （ドロップ）が切り替わりの瞬間に来るようにする。その「盛り上がる点」を、
/// 直前 [beforeWindowMs] の平均より [jumpDb] 以上大きくなる最初の点として探す。
/// 出る側は逆に、そこから曲末まで平均が [jumpDb] 以上落ちる最初の点を探す。
class MixPointDetector {
  MixPointDetector._();

  /// 「ぐっと上がった/下がった」とみなす差（dB）
  static const jumpDb = 6.0;

  /// 比較に使う直前の長さ（ミリ秒）。8〜16 小節のイントロを想定
  static const beforeWindowMs = 8000;

  /// 上がった後がしばらく続くことを確かめる長さ（ミリ秒）
  static const afterWindowMs = 2000;

  /// 落ち込んだ後がしばらく続くことを確かめる長さ（ミリ秒）。
  /// 短いブレイク（数秒静かになってすぐ戻る）をアウトロと間違えないよう長めに取る
  static const afterOutWindowMs = 8000;

  /// ミックスイン点を曲頭から探す範囲（ミリ秒）
  static const inSearchMs = 60000;

  /// ミックスアウト点を曲末から探す範囲（ミリ秒）
  static const outSearchMs = 60000;

  /// 無音とみなす閾値（ピーク比 dB）
  static const silenceDb = -40.0;

  /// 包絡を平滑する長さ（ミリ秒）
  static const smoothMs = 250;

  /// 見つけた点の前後に最低限ほしい長さ（ミリ秒）。短すぎる場合は「無し」にする
  static const minMarginMs = 2000;

  /// 波形を dB（ピーク比）に直して [smoothMs] で平滑したもの（EnergyProfile と共用）
  static List<double> smoothedDb(List<double> waveform, int durationMs) {
    final n = waveform.length;
    final msPer = durationMs / n;
    final db = List<double>.generate(
        n, (i) => 20 * log(max(waveform[i], 1e-3)) / ln10);
    final k = max(1, (smoothMs / msPer).round());
    return _movingAverage(db, k);
  }

  /// 音が鳴っている範囲（点の添字 start〜end）。解析済みの無音と、波形から見た無音の厳しい方
  static (int, int) soundRange(
    List<double> smooth,
    int durationMs, {
    int leadingSilenceMs = 0,
    int? trailingSilenceMs,
  }) {
    final n = smooth.length;
    final msPer = durationMs / n;
    int idx(int ms) => (ms / msPer).round().clamp(0, n);
    var soundStart = idx(leadingSilenceMs);
    while (soundStart < n && smooth[soundStart] <= silenceDb) {
      soundStart++;
    }
    var soundEnd = n - (trailingSilenceMs == null ? 0 : idx(trailingSilenceMs));
    while (soundEnd > soundStart && smooth[soundEnd - 1] <= silenceDb) {
      soundEnd--;
    }
    return (soundStart, soundEnd);
  }

  static MixPoints fromWaveform(
    List<double> waveform,
    int durationMs, {
    int leadingSilenceMs = 0,
    int? trailingSilenceMs,
  }) {
    final n = waveform.length;
    if (n < 50 || durationMs <= 0) return MixPoints.none;
    final msPer = durationMs / n;
    int idx(int ms) => (ms / msPer).round().clamp(0, n);

    final smooth = smoothedDb(waveform, durationMs);
    final (soundStart, soundEnd) = soundRange(smooth, durationMs,
        leadingSilenceMs: leadingSilenceMs, trailingSilenceMs: trailingSilenceMs);
    if (soundEnd - soundStart < idx(minMarginMs * 2)) return MixPoints.none;

    final before = max(1, idx(beforeWindowMs));
    final after = max(1, idx(afterWindowMs));
    final afterOut = max(1, idx(afterOutWindowMs));
    final margin = idx(minMarginMs);

    // --- ミックスイン: 直後 2 秒の平均が直前より +6dB になる最初の点 ---
    // 条件は本当の立ち上がりの少し手前で満たされ始める（直後の窓に大きい部分が
    // 入ってくるため）ので、その前後で最も急に上がる所を立ち上がりとする
    int? mixIn;
    final inEnd = min(soundStart + idx(inSearchMs), soundEnd - after);
    for (var t = soundStart + margin; t < inEnd; t++) {
      final b = mean(smooth, max(soundStart, t - before), t);
      final a = mean(smooth, t, t + after);
      if (a - b >= jumpDb) {
        final onset = _steepest(smooth, max(soundStart, t - after),
            min(t + after, soundEnd - 1), rising: true);
        // 曲頭に近すぎる立ち上がりは、重ねる余地が無いので使わない
        if (onset - soundStart >= margin) mixIn = onset;
        break;
      }
    }

    // --- ミックスアウト: 直後 8 秒の平均が直前より -6dB になり、
    //     そのまま曲末まで戻らない（残りの平均も -3dB 以下）最初の点 ---
    int? mixOut;
    final outStart = max(soundStart + margin + before, soundEnd - idx(outSearchMs));
    for (var t = outStart; t < soundEnd - margin; t++) {
      final b = mean(smooth, t - before, t);
      final a = mean(smooth, t, min(t + afterOut, soundEnd));
      final rest = mean(smooth, t, soundEnd);
      if (b - a >= jumpDb && b - rest >= jumpDb / 2) {
        mixOut = _steepest(smooth, max(soundStart, t - afterOut),
            min(t + afterOut, soundEnd - 1), rising: false);
        break;
      }
    }
    // 入る点より前で出てしまうような矛盾は捨てる
    if (mixIn != null && mixOut != null && mixOut <= mixIn) mixOut = null;

    return MixPoints(
      mixInMs: mixIn == null ? null : (mixIn * msPer).round(),
      mixOutMs: mixOut == null ? null : (mixOut * msPer).round(),
    );
  }

  static List<double> _movingAverage(List<double> v, int k) {
    if (k <= 1) return v;
    final n = v.length;
    final out = List<double>.filled(n, 0);
    var sum = 0.0;
    final half = k ~/ 2;
    // 端は窓を縮める
    for (var i = 0; i < n; i++) {
      final lo = max(0, i - half);
      final hi = min(n, i + half + 1);
      if (i == 0) {
        for (var j = lo; j < hi; j++) {
          sum += v[j];
        }
      } else {
        final prevLo = max(0, i - 1 - half);
        final prevHi = min(n, i - 1 + half + 1);
        if (lo > prevLo) sum -= v[prevLo];
        if (hi > prevHi) sum += v[hi - 1];
      }
      out[i] = sum / (hi - lo);
    }
    return out;
  }

  /// [from]〜[to] の平均（空なら from の値）
  static double mean(List<double> v, int from, int to) {
    if (to <= from) return v[min(from, v.length - 1)];
    var s = 0.0;
    for (var i = from; i < to; i++) {
      s += v[i];
    }
    return s / (to - from);
  }

  /// [from]〜[to] で隣との差が最も大きく（[rising] なら上がる方向に）なる点
  static int _steepest(List<double> v, int from, int to, {required bool rising}) {
    var best = from;
    var bestDelta = double.negativeInfinity;
    for (var i = from; i < to; i++) {
      final d = rising ? v[i + 1] - v[i] : v[i] - v[i + 1];
      if (d > bestDelta) {
        bestDelta = d;
        best = i + 1;
      }
    }
    return best;
  }
}
