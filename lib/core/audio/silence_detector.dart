import 'dart:math';
import 'dart:typed_data';

/// 曲頭・曲末の無音の長さ（ミリ秒）。[trailingMs] は曲末まで PCM が無いとき null
class SilenceInfo {
  const SilenceInfo({required this.leadingMs, required this.trailingMs});
  final int leadingMs;
  final int? trailingMs;
}

/// 曲頭・曲末の無音区間をモノラル PCM から求める（純Dart・副作用なし）。
///
/// クロスフェードで「無音同士を重ねてしまい、つながって聞こえない」のを避けるため、
/// 音が実際に鳴っている範囲を知るのに使う。
class SilenceDetector {
  SilenceDetector._();

  /// RMS を取る窓（ミリ秒）。短いと一瞬の無音に引っかかり、長いと精度が落ちる
  static const windowMs = 50;

  /// 曲中の最大 RMS に対してこの比率以下を無音とみなす（-40dB）
  static const relativeThreshold = 0.01;

  /// 絶対下限（16bit フルスケール比）。ノイズフロアで誤って「音あり」にしない
  static const absoluteThreshold = 0.002;

  /// [truncated] が true なら PCM が曲末まで届いていない（曲末の無音は不明）
  static SilenceInfo detect(Int16List pcm, int sampleRate,
      {bool truncated = false}) {
    final win = max(1, sampleRate * windowMs ~/ 1000);
    final n = pcm.length ~/ win;
    if (n == 0) return SilenceInfo(leadingMs: 0, trailingMs: truncated ? null : 0);

    final rms = Float64List(n);
    var peak = 0.0;
    for (var w = 0; w < n; w++) {
      var acc = 0.0;
      final base = w * win;
      for (var i = 0; i < win; i++) {
        final v = pcm[base + i] / 32768.0;
        acc += v * v;
      }
      rms[w] = sqrt(acc / win);
      if (rms[w] > peak) peak = rms[w];
    }
    final threshold = max(peak * relativeThreshold, absoluteThreshold);

    var first = 0;
    while (first < n && rms[first] <= threshold) {
      first++;
    }
    if (first == n) {
      // 全部無音
      final total = n * windowMs;
      return SilenceInfo(leadingMs: total, trailingMs: truncated ? null : total);
    }
    var last = n - 1;
    while (last > first && rms[last] <= threshold) {
      last--;
    }
    return SilenceInfo(
      leadingMs: first * windowMs,
      trailingMs: truncated ? null : (n - 1 - last) * windowMs,
    );
  }
}
