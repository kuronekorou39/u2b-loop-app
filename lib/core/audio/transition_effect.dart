import 'sfx_library.dart';

/// 曲の切り替わりの演出（出ていく曲にかける処理と、重ねる効果音）。
///
/// - フィルタ系（エコーアウト / フィルタースイープ）: ベーススワップの位置
///   （[CrossfadeCurve.bassSwapAt]）から切替点までの間、出る曲にかける
/// - 効果音系（ライザー / インパクト）: 効果音用のプレイヤーで曲に重ねる。
///   ライザーは終わりを切替点に合わせ、インパクトは切替点で鳴らす
/// - トリック系（ブレーキ / スピンバック / ループロール）: 切替点まで前の曲だけを聴かせ、
///   その瞬間に次の曲へ切り替える（音量曲線とベーススワップは使わない）
enum TransitionEffect {
  none('なし', '音量の曲線だけでつなぐ'),
  echoOut('エコーアウト', '前の曲にエコーをかけ、尾を引かせながら消す'),
  filterSweep('フィルタースイープ', '前の曲をだんだんこもらせながら消す'),
  riser('ライザー', '切り替わりに向けて上がっていく効果音を重ね、前の曲はこもらせる'),
  riserImpact('ライザー＋インパクト', '上がっていく効果音のあと、切り替わりの瞬間に一撃'),
  impact('インパクト', '切り替わりの瞬間に一撃と余韻を重ねる'),
  brake('ブレーキ', '前の曲をレコードが止まるように遅くして止め、その瞬間に次の曲へ'),
  spinback('スピンバック', '前の曲を逆回転の音で巻き取り、その瞬間に次の曲へ'),
  loopRoll('ループロール', '前の曲の最後の 1 小節を 1/2 → 1/4 → 1/8 拍と細かく刻み、次の曲へ');

  const TransitionEffect(this.label, this.description);

  final String label;
  final String description;

  /// 既定。こもらせて抜くのが一番自然で、効かなくても（開いたままのローパス）害がない
  static const defaultEffect = filterSweep;

  static TransitionEffect fromName(String? name) =>
      values.where((e) => e.name == name).firstOrNull ?? defaultEffect;

  /// 出る曲のローパスを閉じていくか（ライザーもこもらせながら上げるのが定石）
  bool get sweepsOut => this == filterSweep || this == riser || this == riserImpact;

  /// 出る曲にエコーを付けるか
  bool get echoesOut => this == echoOut;

  /// 切替点の手前で鳴らし、終わりを切替点に合わせる効果音
  SfxRole? get leadInSfx => switch (this) {
        riser || riserImpact => SfxRole.riser,
        spinback => SfxRole.spinback,
        _ => null,
      };

  /// 切替点の瞬間に鳴らす効果音があるか
  bool get impactAtCut => this == riserImpact || this == impact;

  bool get usesSfx => leadInSfx != null || impactAtCut;

  /// 切替点までは前の曲だけ、その瞬間に次の曲へ（音量曲線・ベーススワップを使わない）
  bool get cutsHard => this == brake || this == spinback || this == loopRoll;
}
