import 'transition_effect.dart';

/// 1 番の終わり（B 点）から次の曲へのつなぎ方。曲ごとに選ぶ。保存は名前。
///
/// 標準は [overlap]。2026-11 の聞き比べで、ふつうの曲は今の重ね方が一番よく、エコー・残響は
/// 「ぶつ切れ」に聞こえた。セリフで終わる曲からセリフで始まる曲へのつなぎでは良かったが、
/// 音からは見分けられないので、自動では切り替えず曲ごとに選ぶ
enum VerseEnding {
  /// DJ ミックスの設定のまま、B 点で重なりが終わる
  overlap('重ねる', null),

  /// B 点まで 100% で鳴らし、最後の 1 拍をエコーで残す。次の曲は B 点で頭から
  echo('エコー', TransitionEffect.echoTail),

  /// B 点まで 100% で鳴らし、最後の音を残響で残す。次の曲は B 点で頭から
  reverb('残響', TransitionEffect.reverbTail);

  const VerseEnding(this.label, this.effect);

  final String label;

  /// 尾の演出（[overlap] は null）
  final TransitionEffect? effect;

  static VerseEnding fromName(String? name) =>
      values.where((e) => e.name == name).firstOrNull ?? overlap;
}
