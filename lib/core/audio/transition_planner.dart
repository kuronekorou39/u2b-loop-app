import '../../models/loop_item.dart';
import 'crossfade_curve.dart';
import 'track_compatibility.dart';
import 'transition_effect.dart';

/// つなぎ方 1 回分の材料（クロスフェードの長さ・曲線・低音・演出・合わせるか）。
/// 手動の設定をまとめたものと、おまかせ（[TransitionPlanner]）が選んだものの両方をこれで表す
class TransitionRecipe {
  const TransitionRecipe({
    required this.beats,
    required this.curve,
    required this.bassSwap,
    required this.effect,
    required this.beatMatch,
    required this.tempoMatch,
    this.name = '',
    this.reason = '',
    this.auto = false,
  });

  /// クロスフェードの長さ（拍）。0 = オフ
  final int beats;
  final CrossfadeCurve curve;
  final bool bassSwap;
  final TransitionEffect effect;
  final bool beatMatch;
  final bool tempoMatch;

  /// おまかせが選んだレシピの名前と理由（手動なら空）
  final String name;
  final String reason;
  final bool auto;

  /// ミックスビューに出す 1 行。例「ドロップ合わせ（テンポ差 2% · ドロップ +11dB）」
  String get summary => reason.isEmpty ? name : '$name（$reason）';

  TransitionRecipe copyWith({int? beats, String? reason}) => TransitionRecipe(
        beats: beats ?? this.beats,
        curve: curve,
        bassSwap: bassSwap,
        effect: effect,
        beatMatch: beatMatch,
        tempoMatch: tempoMatch,
        name: name,
        reason: reason ?? this.reason,
        auto: auto,
      );

  @override
  String toString() => 'TransitionRecipe($beats拍 ${curve.name} bass=$bassSwap '
      '${effect.name} beat=$beatMatch tempo=$tempoMatch $summary)';
}

/// おまかせ: 2 曲の解析結果から、つなぎのレシピを選ぶ（純粋関数）。
///
/// Apple AutoMix / Spotify の Automix と同じ考え方で、曲によっては何もしない
/// （単純なフェードだけ）のも正しい選択。入力はすべて解析済みの値:
/// テンポ（倍/半は同一視）、拍の格子の信頼度、キーの相性、入る曲のドロップの跳ね幅、
/// 出る曲の終わり方（フェードアウトか）、エネルギー差（出る曲の末尾と入る曲の頭の平均 dB）。
/// 分からない値は「その条件は満たさない」として扱う（情報が無いときは無難な側へ倒れる）
class TransitionPlanner {
  TransitionPlanner._();

  /// テンポを寄せられる上限（これを超えると合わせない）
  static const tempoLimitPercent = TrackCompatibility.maxTempoAdjustPercent;

  /// 「強いドロップ」とみなす跳ね幅（dB）。検出の下限（6dB）より上
  static const strongDropDb = 9.0;

  /// エネルギーが上がる / 下がるとみなす差（dB）
  static const energyStepDb = 3.0;

  /// 入る曲が速い / 遅いとみなすテンポ差（%）
  static const fasterPercent = 3.0;

  /// 出る曲がフェードアウトで終わるとみなす、末尾 10 秒の落ち込み（dB）
  static const fadeOutDb = -6.0;

  /// 静かな曲（ピーク比の平均 dB がこれ未満 = 疎・ダイナミック）。**実曲で見て調整する値**
  static const quietDb = -16.0;

  /// キーが合わない 2 曲を長く重ねると濁るので、この拍数までに縮める
  static const keyClashMaxBeats = 8;

  static TransitionRecipe plan(LoopItem out, LoopItem next) {
    final tempoDiff = TrackCompatibility.tempoDiffPercent(out.bpm, next.bpm);
    final ratio = TrackCompatibility.tempoRatio(out.bpm, next.bpm);
    // 入る曲が出る曲よりどれだけ速いか（%、倍/半は折り畳む）
    final faster = ratio == null ? null : (1 / ratio - 1) * 100;
    final outGrid = out.beatGrid;
    final inGrid = next.beatGrid;
    final live = (outGrid != null && !outGrid.reliable) || (inGrid != null && !inGrid.reliable);
    final energy = next.headDb != null && out.tailDb != null ? next.headDb! - out.tailDb! : null;
    final drop = next.mixInMs == null ? null : next.dropDb;
    final quiet = out.tailDb != null &&
        next.headDb != null &&
        out.tailDb! < quietDb &&
        next.headDb! < quietDb;
    final fadesOut = out.endFadeDb != null && out.endFadeDb! <= fadeOutDb;
    final keyClash = out.musicalKey != null &&
        next.musicalKey != null &&
        TrackCompatibility.keyScore(out.musicalKey, next.musicalKey) == 0;

    final facts = <String>[
      if (tempoDiff != null) 'テンポ差 ${tempoDiff.round()}%',
    ];
    TransitionRecipe recipe;
    if (quiet) {
      facts.add('静かな曲同士');
      recipe = _make('そっと重ねる', 4, CrossfadeCurve.equalPower,
          bass: false, effect: TransitionEffect.none, match: false);
    } else if (live) {
      facts.add('ビートが不安定');
      recipe = _make('ゆるく重ねる', 8, CrossfadeCurve.equalPower,
          bass: false, effect: TransitionEffect.none, match: false);
    } else if (tempoDiff == null) {
      facts.add('テンポ不明');
      recipe = _make('標準', 8, CrossfadeCurve.equalPower,
          bass: true, effect: TransitionEffect.filterSweep, match: false);
    } else if (tempoDiff > tempoLimitPercent) {
      recipe = _make('短く切り替え', 4, CrossfadeCurve.equalPower,
          bass: false, effect: TransitionEffect.impact, match: false);
    } else if (fadesOut) {
      facts.add('フェードアウト');
      recipe = _make('フェードアウトに重ねる', 16, CrossfadeCurve.nextFirst,
          bass: true, effect: TransitionEffect.none, match: true);
    } else if (drop != null && drop >= strongDropDb) {
      facts.add('ドロップ +${drop.round()}dB');
      recipe = _make('ドロップ合わせ', 8, CrossfadeCurve.cut,
          bass: true, effect: TransitionEffect.riserImpact, match: true);
    } else if ((faster ?? 0) >= fasterPercent || (energy ?? 0) >= energyStepDb) {
      facts.add(_energyFact(faster, energy, up: true));
      recipe = _make('盛り上げ', 8, CrossfadeCurve.nextFirst,
          bass: true, effect: TransitionEffect.riser, match: true);
    } else if ((faster ?? 0) <= -fasterPercent || (energy ?? 0) <= -energyStepDb) {
      facts.add(_energyFact(faster, energy, up: false));
      recipe = _make('落ち着かせ', 16, CrossfadeCurve.equalPower,
          bass: true, effect: TransitionEffect.echoOut, match: true);
    } else {
      recipe = _make('ブレンド', 16, CrossfadeCurve.nextFirst,
          bass: true, effect: TransitionEffect.filterSweep, match: true);
    }
    if (keyClash && recipe.beats > keyClashMaxBeats) {
      facts.add('キー不一致で短め');
      recipe = recipe.copyWith(beats: keyClashMaxBeats);
    }
    return recipe.copyWith(reason: facts.join(' · '));
  }

  static String _energyFact(double? faster, double? energy, {required bool up}) {
    if (faster != null && (up ? faster >= fasterPercent : faster <= -fasterPercent)) {
      return '入る曲が${up ? '速い' : '遅い'}';
    }
    final e = energy ?? 0;
    return '入る曲が ${e >= 0 ? '+' : ''}${e.round()}dB';
  }

  static TransitionRecipe _make(String name, int beats, CrossfadeCurve curve,
          {required bool bass, required TransitionEffect effect, required bool match}) =>
      TransitionRecipe(
        beats: beats,
        curve: curve,
        bassSwap: bass,
        effect: effect,
        beatMatch: match,
        tempoMatch: match,
        name: name,
        auto: true,
      );
}
