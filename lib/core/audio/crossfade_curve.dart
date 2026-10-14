import 'dart:math';

/// クロスフェードの音量曲線（つなぎ方）。
///
/// 進捗 [t]（0 = 交差の開始、1 = 切替点）に対する出ていく曲・入ってくる曲の音量比を返す。
/// 対称な等パワーだけだと中間で両方が半端に混ざって「ぼやける」ので、
/// DJ らしい非対称なつなぎも選べるようにしてある。
enum CrossfadeCurve {
  /// 等パワー: cos / sin。中間で合計の音圧が落ちない、無難なつなぎ
  equalPower('等パワー', '両方をなめらかに入れ替える。無難'),

  /// 次曲先行: 入る曲を早めに 7 割まで上げて重ね、切替直前に出る曲を一気に落とす
  nextFirst('次曲先行', '次の曲を早めに重ねて、切り替わりの直前で前の曲を一気に落とす。DJ らしい'),

  /// 直線: 単純な線形。中間で少し音圧が落ちる
  linear('直線', '単純に入れ替える。中間で少し音が薄くなる'),

  /// カット: 切替点まで前の曲のまま、その瞬間に次の曲へ（ドロップ合わせと組み合わせると気持ちいい）
  cut('カット', '切替点まで前の曲のまま、その瞬間に次の曲へ。ドロップ合わせ向き');

  const CrossfadeCurve(this.label, this.description);

  final String label;
  final String description;

  /// 既定
  static const defaultCurve = equalPower;

  static CrossfadeCurve fromName(String? name) =>
      values.where((c) => c.name == name).firstOrNull ?? defaultCurve;

  /// ベーススワップ（出る曲と入る曲の低音を入れ替える）をする進捗。
  /// 入る曲が主役になる所: 等パワー・直線は中間、次曲先行は出る曲を落とし始める所、カットは切替点
  double get bassSwapAt => switch (this) {
        equalPower || linear => 0.5,
        nextFirst => 0.7,
        cut => 1.0,
      };

  /// [t] は 0〜1。戻り値は 0〜1 の音量比
  ({double out, double in_}) levels(double t) {
    final p = t.clamp(0.0, 1.0);
    switch (this) {
      case equalPower:
        return (out: cos(p * pi / 2), in_: sin(p * pi / 2));
      case linear:
        return (out: 1 - p, in_: p);
      case nextFirst:
        // 入る曲: 前半で 0.7 まで滑らかに上げ、後半で 1 へ
        final inLevel = p < 0.5
            ? 0.7 * sin(p / 0.5 * pi / 2)
            : 0.7 + 0.3 * ((p - 0.5) / 0.5);
        // 出る曲: 7 割の時点までそのまま、残り 3 割で一気に落とす
        // （cos(π/2) はごく小さい負の値になるので 0 で止める）
        final outLevel = p < 0.7 ? 1.0 : cos((p - 0.7) / 0.3 * pi / 2);
        return (out: outLevel.clamp(0.0, 1.0), in_: inLevel.clamp(0.0, 1.0));
      case cut:
        return p >= 1 ? (out: 0, in_: 1) : (out: 1, in_: 0);
    }
  }
}
