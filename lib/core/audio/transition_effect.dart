/// 曲の切り替わりで出ていく曲にかける演出。
///
/// DJ の「エコーアウト」（出る曲にエコーをかけて尾を引かせながら消す）と
/// 「フィルタースイープ」（ローパスを閉じてこもらせながら消す）。
/// どちらもベーススワップの位置（[CrossfadeCurve.bassSwapAt]）から切替点までの間にかける。
enum TransitionEffect {
  none('なし', '音量の曲線だけでつなぐ'),
  echoOut('エコーアウト', '前の曲にエコーをかけ、尾を引かせながら消す'),
  filterSweep('フィルタースイープ', '前の曲をだんだんこもらせながら消す');

  const TransitionEffect(this.label, this.description);

  final String label;
  final String description;

  /// 既定。こもらせて抜くのが一番自然で、効かなくても（開いたままのローパス）害がない
  static const defaultEffect = filterSweep;

  static TransitionEffect fromName(String? name) =>
      values.where((e) => e.name == name).firstOrNull ?? defaultEffect;
}
