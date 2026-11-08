/// 再生速度の表示「1.0x」「1.25x」「0.5x」。小数は 2 桁まで
/// （DJ のテンポ合わせで速度が 1.00000044 のような値になり、そのまま出ていた）
String rateLabel(double rate) {
  final r = (rate * 100).round() / 100;
  if (r == r.roundToDouble()) return '${r.toStringAsFixed(1)}x';
  var s = r.toStringAsFixed(2);
  if (s.endsWith('0')) s = s.substring(0, s.length - 1);
  return '${s}x';
}

/// 速度の候補 [a] と今の速度 [b] が同じとみなせるか（表示の 2 桁で比べる）
bool sameRate(double a, double b) => (a - b).abs() < 0.005;
