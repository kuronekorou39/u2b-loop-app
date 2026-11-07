import 'sfx_library.dart';

/// 曲の切り替わりの演出（出ていく曲にかける処理と、重ねる効果音）。
///
/// - フィルタ系（フィルタースイープ）: ベーススワップの位置
///   （[CrossfadeCurve.bassSwapAt]）から切替点までの間、出る曲にかける
/// - 効果音系（ライザー / インパクト）: 効果音用のプレイヤーで曲に重ねる。
///   ライザーは終わりを切替点に合わせ、インパクトは切替点で鳴らす
/// - トリック系（ブレーキ / スピンバック / ループロール）: 切替点まで前の曲だけを聴かせ、
///   その瞬間に次の曲へ切り替える（音量曲線とベーススワップは使わない）
///
/// エコーアウトは v1.97.1 で廃止（端末の libmpv に aecho が無く作れない。[AudioFilters] 参照）。
/// 保存済みの 'echoOut' は [fromName] で既定に落ちる
enum TransitionEffect {
  none('なし', '音量の曲線だけでつなぐ'),
  filterSweep('フィルタースイープ', '前の曲をだんだんこもらせながら消す'),
  riser('ライザー', '切り替わりに向けて上がっていく効果音を重ね、前の曲はこもらせる'),
  riserImpact('ライザー＋インパクト', '上がっていく効果音のあと、切り替わりの瞬間に一撃'),
  impact('インパクト', '切り替わりの瞬間に一撃と余韻を重ねる'),
  brake('ブレーキ', '前の曲をレコードが止まるように遅くして止め、その瞬間に次の曲へ'),
  spinback('スピンバック', '前の曲を逆回転の音で巻き取り、その瞬間に次の曲へ'),
  loopRoll('ループロール', '前の曲の最後の 1 小節を 1/2 → 1/4 → 1/8 拍と細かく刻み、次の曲へ'),
  tease('焦らし', '次の曲を 1〜2 拍だけ出しては前の曲に戻すのを繰り返し、小節の頭で切り替える');

  const TransitionEffect(this.label, this.description);

  final String label;
  final String description;

  /// 既定。こもらせて抜くのが一番自然で、効かなくても（開いたままのローパス）害がない
  static const defaultEffect = filterSweep;

  static TransitionEffect fromName(String? name) =>
      values.where((e) => e.name == name).firstOrNull ?? defaultEffect;

  /// 出る曲のローパスを閉じていくか（ライザーもこもらせながら上げるのが定石）
  bool get sweepsOut => this == filterSweep || this == riser || this == riserImpact;

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

  /// 焦らしの段取り: (切替点の何拍前, 次の曲を出すか)。その拍から次の段取りまでその状態。
  /// 4 小節（16 拍）のうち、2 小節目の頭で 1 拍、3 小節目の頭で 2 拍、
  /// 最後の小節は 1 拍ごとに出し入れし、最後の 1 拍は前の曲に戻してから切替点で次の曲へ
  static const teaseSteps = <(double, bool)>[
    (12, true), (11, false),
    (8, true), (6, false),
    (4, true), (3, false), (2, true), (1, false),
  ];

  /// 焦らしに要る長さ（拍）
  static const teaseBeats = 16;
}
