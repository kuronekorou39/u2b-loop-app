import 'dart:math';

/// 音量正規化（純 Dart・副作用なし）。
///
/// 画面に出す波形はピークで正規化してあるので、そこから曲の大きさは分からない
/// （v1.97.1 までは波形の RMS から計算していたため、どの曲も下限の 20% に張り付いていた）。
/// 代わりに、波形を作るときにネイティブ側がデコードした 16bit PCM の RMS（絶対値）から
/// 曲全体の RMS を dBFS で測り（[measureDb]）、曲に保存して使う（LoopItem.loudnessDb）。
///
/// 合わせ方は「大きい曲を下げる」だけ（[maxBoostDb] = 0）。mpv の音量は 100 を超えると
/// クリップするので上げない。下げ幅にも下限（[maxCutDb]）を置き、聞こえなくならないようにする
class Loudness {
  Loudness._();

  /// 曲全体の RMS の目標（dBFS）。YouTube の曲はおおむね −14〜−17、CD 音源は −9〜−12
  static const targetDb = -14.0;

  /// これより下げない（−12dB = 25%）
  static const maxCutDb = -12.0;

  /// これより上げない（上げるとクリップする）
  static const maxBoostDb = 0.0;

  static const _fullScale = 32768.0;

  /// デコードの塊ごとの RMS（16bit の単位）から曲全体の RMS を dBFS で。無音・空なら null
  static double? measureDb(List<int> rmsChunks) {
    if (rmsChunks.isEmpty) return null;
    var sum = 0.0;
    for (final r in rmsChunks) {
      sum += r.toDouble() * r;
    }
    final rms = sqrt(sum / rmsChunks.length);
    if (rms < 1) return null;
    return 20 * log(rms / _fullScale) / ln10;
  }

  /// 曲の大きさ [loudnessDb] に対する補正（dB）。未計測なら 0
  static double gainDb(double? loudnessDb) =>
      loudnessDb == null ? 0 : (targetDb - loudnessDb).clamp(maxCutDb, maxBoostDb);

  /// 補正の倍率（0.25〜1）
  static double gain(double? loudnessDb) => pow(10, gainDb(loudnessDb) / 20).toDouble();

  /// 基準の音量 [base]（0〜100）にかけた、その曲の音量
  static double volumeFor(double? loudnessDb, {double base = 100}) =>
      (base * gain(loudnessDb)).clamp(0.0, 100.0);

  /// 今の曲の音量 [fromVolume] を、補正を外して次の曲の補正をかけ直した値
  /// （スライダーで動かした分を引き継ぐ）
  static double carry(double fromVolume, double? fromDb, double? toDb) =>
      (fromVolume / gain(fromDb) * gain(toDb)).clamp(0.0, 100.0);
}
