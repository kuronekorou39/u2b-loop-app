/// AB 設定で共通の定数。
/// （以前ここにあった A/B 行のウィジェット buildPointRow は AbEditControls に置き換わり、
/// どこからも使われていなかったので削除）
class LoopControls {
  LoopControls._();

  /// 微調整のステップ候補（秒）
  static const steps = [0.001, 0.01, 0.1, 1.0, 10.0, 100.0];
}
