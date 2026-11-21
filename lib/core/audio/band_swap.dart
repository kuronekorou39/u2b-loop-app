import 'crossfade_curve.dart';

/// 交差中に前の曲と次の曲の帯域を入れ替えるか（DJ の EQ ミックス）。
///
/// - [bass]: 低音だけ。次の曲は低音を切って重ね、[CrossfadeCurve.bassSwapAt] で入れ替える
/// - [three]: 高音 → 中音 → 低音の順にずらして入れ替える（ハウス・テクノの長いつなぎの定石）。
///   次の曲は低音と中音を切って重ね（ハイハットが先に入る）、まず前の曲の高音を抜き、
///   次に中音（歌・メロディ）を入れ替え、最後に低音を入れ替える。
///   歌が重なる組でも、中音を入れ替えれば 2 つの歌が同時に前に出ない
enum BandSwap {
  none('なし'),
  bass('低音'),
  three('高・中・低');

  const BandSwap(this.label);

  final String label;

  static const defaultValue = bass;

  static BandSwap fromName(String? name) =>
      values.where((b) => b.name == name).firstOrNull ?? defaultValue;

  /// 前の曲の高音を抜き始める進捗（低音の入れ替えの半分の所）
  static double highAt(CrossfadeCurve curve) => curve.bassSwapAt * 0.5;

  /// 中音を入れ替え始める進捗（高音と低音の間）
  static double midAt(CrossfadeCurve curve) => curve.bassSwapAt * 0.75;
}
