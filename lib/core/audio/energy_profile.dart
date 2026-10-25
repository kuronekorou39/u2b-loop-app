import 'mix_point_detector.dart';

/// 曲の「音量の流れ」の要約（波形から。純 Dart・副作用なし）。おまかせ（TransitionPlanner）が
/// 2 曲のエネルギー差や終わり方を見るのに使う。
///
/// 値はすべて **その曲のピークに対する dB**（波形がピークで正規化されているため）。
/// 曲同士の絶対的な音量差ではなく「どれだけ詰まっているか / 疎か」の目安。
/// YouTube はラウドネスが揃えられているので、曲同士の比較にもおおよそ使える
class EnergyProfile {
  const EnergyProfile({this.headDb, this.tailDb, this.endFadeDb, this.dropDb});

  /// 曲頭（無音を除いた最初の [headWindowMs]）の平均
  final double? headDb;

  /// 曲末（無音を除いた最後の [tailWindowMs]）の平均
  final double? tailDb;

  /// 終わり方: 最後の [fadeWindowMs] の平均 − その直前 [fadeWindowMs] の平均。
  /// 大きく負ならフェードアウト、0 付近なら急に終わる。短い曲は null
  final double? endFadeDb;

  /// ドロップの跳ね幅: ミックスイン点の直後 2 秒の平均 − 直前 8 秒の平均。ミックスイン点が無ければ null
  final double? dropDb;

  static const headWindowMs = 30000;
  static const tailWindowMs = 30000;
  static const fadeWindowMs = 10000;
  static const dropBeforeMs = MixPointDetector.beforeWindowMs;
  static const dropAfterMs = MixPointDetector.afterWindowMs;

  bool get isEmpty => headDb == null && tailDb == null && endFadeDb == null && dropDb == null;

  /// [curve] の 1 点の長さ（ミリ秒）。3 分の曲で 90 点ほど
  static const curveStepMs = 2000;

  /// 音量の流れそのもの: 曲頭から [curveStepMs] ごとの平均 dB（ピーク比、無音は −60 dB）。
  /// 入り口を選ぶ（EntryPlanner）のに使う。[durationMs] の終わりまで、端数の区間も 1 点にする
  static List<double> curve(List<double> waveform, int durationMs) {
    final n = waveform.length;
    if (n < 2 || durationMs <= 0) return const [];
    final smooth = MixPointDetector.smoothedDb(waveform, durationMs);
    final msPer = durationMs / n;
    final points = (durationMs / curveStepMs).ceil();
    return List<double>.generate(points, (i) {
      final from = (i * curveStepMs / msPer).round().clamp(0, n - 1);
      final to = ((i + 1) * curveStepMs / msPer).round().clamp(from + 1, n);
      return MixPointDetector.mean(smooth, from, to);
    });
  }

  static EnergyProfile fromWaveform(
    List<double> waveform,
    int durationMs, {
    int leadingSilenceMs = 0,
    int? trailingSilenceMs,
    int? mixInMs,
  }) {
    final n = waveform.length;
    if (n < 50 || durationMs <= 0) return const EnergyProfile();
    final msPer = durationMs / n;
    int idx(int ms) => (ms / msPer).round().clamp(0, n);

    final smooth = MixPointDetector.smoothedDb(waveform, durationMs);
    final (soundStart, soundEnd) = MixPointDetector.soundRange(smooth, durationMs,
        leadingSilenceMs: leadingSilenceMs, trailingSilenceMs: trailingSilenceMs);
    if (soundEnd - soundStart < idx(2000)) return const EnergyProfile();

    final head = MixPointDetector.mean(
        smooth, soundStart, (soundStart + idx(headWindowMs)).clamp(soundStart + 1, soundEnd));
    final tail = MixPointDetector.mean(
        smooth, (soundEnd - idx(tailWindowMs)).clamp(soundStart, soundEnd - 1), soundEnd);

    double? endFade;
    final fade = idx(fadeWindowMs);
    if (soundEnd - soundStart >= fade * 2 && fade > 0) {
      final last = MixPointDetector.mean(smooth, soundEnd - fade, soundEnd);
      final before = MixPointDetector.mean(smooth, soundEnd - fade * 2, soundEnd - fade);
      endFade = last - before;
    }

    double? drop;
    if (mixInMs != null) {
      final at = idx(mixInMs);
      final from = (at - idx(dropBeforeMs)).clamp(soundStart, at);
      final to = (at + idx(dropAfterMs)).clamp(at, soundEnd);
      if (at > from && to > at) {
        drop = MixPointDetector.mean(smooth, at, to) - MixPointDetector.mean(smooth, from, at);
      }
    }

    return EnergyProfile(headDb: head, tailDb: tail, endFadeDb: endFade, dropDb: drop);
  }

  @override
  String toString() => 'EnergyProfile(head ${_f(headDb)} tail ${_f(tailDb)} '
      'endFade ${_f(endFadeDb)} drop ${_f(dropDb)})';

  static String _f(double? v) => v == null ? '-' : '${v.toStringAsFixed(1)}dB';
}
