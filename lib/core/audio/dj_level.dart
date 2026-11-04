import 'crossfade_curve.dart';
import 'transition_effect.dart';

/// DJ のつなぎ方の段階。選ぶと個々の設定をまとめて決める（v1.136.0）。
/// 個々の設定がどの段階とも一致しなければカスタム（[DjLevel.of] が null）
enum DjLevel {
  /// 曲には手を加えず、きれいに重ねるだけ（等パワー・8 拍・演出・効果音・テンポ合わせなし）
  gentle('控えめ'),

  /// おまかせ（曲の組み合わせからつなぎ方を選ぶ。v1.135 までの既定）
  normal('普通'),

  /// おまかせに、派手な演出・フレーズ単位の長いつなぎ・歌のぶつかり回避を足す
  pro('ガチ');

  const DjLevel(this.label);
  final String label;

  static const defaultLevel = normal;

  /// 控えめのクロスフェードの長さ（拍）
  static const gentleBeats = 8;

  /// 今の設定がどの段階か。どれとも一致しなければ null（カスタム）
  static DjLevel? of(DjSettings s) {
    if (!s.autoMix &&
        !s.pro &&
        s.curve == CrossfadeCurve.equalPower &&
        s.effect == TransitionEffect.none &&
        !s.bassSwap &&
        !s.tempoMatch &&
        !s.beatMatch &&
        !s.smartEntry &&
        !s.mixPointAlign) {
      return gentle;
    }
    if (s.autoMix && s.bassSwap && s.tempoMatch && s.beatMatch && s.smartEntry && s.mixPointAlign) {
      return s.pro ? pro : normal;
    }
    return null;
  }
}

/// [DjLevel] を決めるのに見る設定
class DjSettings {
  const DjSettings({
    required this.autoMix,
    required this.pro,
    required this.curve,
    required this.effect,
    required this.bassSwap,
    required this.tempoMatch,
    required this.beatMatch,
    required this.smartEntry,
    required this.mixPointAlign,
  });

  final bool autoMix;
  final bool pro;
  final CrossfadeCurve curve;
  final TransitionEffect effect;
  final bool bassSwap;
  final bool tempoMatch;
  final bool beatMatch;
  final bool smartEntry;
  final bool mixPointAlign;
}
