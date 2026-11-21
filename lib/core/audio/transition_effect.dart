import 'sfx_library.dart';

/// 曲の切り替わりの演出（出ていく曲・入ってくる曲にかける処理と、重ねる効果音）。
///
/// - フィルタ系（フィルタースイープ / フィルターイン）: イコライザーで前の曲をこもらせて抜く・
///   次の曲をこもった音から開いて入れる
/// - 曲の音から作るもの（エコーアウト / 残響で消す / スピンバック）: 前の曲の切替点の手前を
///   端末でデコードして加工し（[TailRenderer]）、効果音用のプレイヤーで鳴らす。端末の再生ライブラリには
///   イコライザーしか無いので、エコー・残響・逆回転はこうして作る
/// - 効果音系（リバースシンバル / クラッシュ / ライザー / インパクト）: 同梱の素材を重ねる。
///   終わりを切替点に合わせるもの（[leadInSfx]）と、切替点で鳴らすもの（[atCutSfx]）がある
/// - トリック系（ブレーキ / スピンバック / ループロール）: 切替点まで前の曲だけを聴かせ、
///   その瞬間に次の曲へ切り替える（音量曲線と帯域の入れ替えは使わない）
///
/// 保存は名前。v1.97.1 で廃止した旧エコーアウト（'echoOut'）は [fromName] で既定に落ちる
/// （新しいエコーアウトは別の名前 [echoTail]）
enum TransitionEffect {
  /// 音量の曲線だけでつなぐ
  none('なし', 'なし'),

  /// 前の曲をだんだんこもらせながら消す
  filterSweep('フィルタースイープ', 'スイープ'),

  /// 次の曲をこもった音から開いて入れる（低音が入れ替わる所で開き切る）
  filterIn('フィルターイン', 'フィルタ入'),

  /// 前の曲の最後の拍を半拍ごとに繰り返し、こもらせながら消す。次の曲は切替点から
  echoTail('エコーアウト', 'エコー'),

  /// 前の曲の最後の音を残響にして広げながら消す。拍を合わせないので、拍が揺れる曲にも
  reverbTail('残響で消す', '残響'),

  /// 切り替わりへ向けて吸い込むシンバルを 1 小節重ねる（大きなライザーより目立たない）
  reverseCymbal('リバースシンバル', '逆シンバル'),

  /// 次の曲の 1 拍目に薄くシンバルを重ねる
  crash('クラッシュ', 'クラッシュ'),

  /// 切り替わりに向けて上がっていく効果音を重ね、前の曲はこもらせる
  riser('ライザー', 'ライザー'),

  /// 上がっていく効果音のあと、切り替わりの瞬間に一撃
  riserImpact('ライザー＋インパクト', 'ライザー＋'),

  /// 切り替わりの瞬間に一撃と余韻を重ねる
  impact('インパクト', 'インパクト'),

  /// 前の曲をレコードが止まるように遅くして止め、その瞬間に次の曲へ
  brake('ブレーキ', 'ブレーキ'),

  /// 前の曲そのものを逆回転で巻き戻し、その瞬間に次の曲へ（作れなければ素材の音）
  spinback('スピンバック', '逆回転'),

  /// 前の曲の最後の 1 小節を 1/2 → 1/4 → 1/8 拍と細かく刻み、次の曲へ
  loopRoll('ループロール', 'ロール');

  const TransitionEffect(this.label, this.short);

  final String label;

  /// 狭い所（設定の DJ ミックスの丸いボタンの下）に出す 5 文字までの名前
  final String short;

  /// 既定。こもらせて抜くのが一番自然で、効かなくても（開いたままのイコライザー）害がない
  static const defaultEffect = filterSweep;

  static TransitionEffect fromName(String? name) =>
      values.where((e) => e.name == name).firstOrNull ?? defaultEffect;

  /// 出る曲を閉じていくか（ライザーもこもらせながら上げるのが定石）
  bool get sweepsOut => this == filterSweep || this == riser || this == riserImpact;

  /// 入る曲をこもった音から開いていくか
  bool get sweepsIn => this == filterIn;

  /// 切替点の手前で鳴らし、終わりを切替点に合わせる効果音
  SfxRole? get leadInSfx => switch (this) {
        riser || riserImpact => SfxRole.riser,
        reverseCymbal => SfxRole.reverseCymbal,
        spinback => SfxRole.spinback,
        _ => null,
      };

  /// 切替点の瞬間から鳴らす音（一撃・シンバル・前の曲から作った尾）
  SfxRole? get atCutSfx => switch (this) {
        riserImpact || impact => SfxRole.impact,
        crash => SfxRole.crash,
        echoTail || reverbTail => SfxRole.tail,
        _ => null,
      };

  /// 切替点の瞬間に鳴らす音があるか
  bool get impactAtCut => atCutSfx != null;

  bool get usesSfx => leadInSfx != null || impactAtCut;

  /// 切替点までは前の曲だけ、その瞬間に次の曲へ（トリックで前の曲の速度・位置が動く）
  bool get cutsHard => this == brake || this == spinback || this == loopRoll;

  /// 切替点で前の曲を止めて次の曲へ切り替える（音量曲線はカット、帯域の入れ替えなし）。
  /// トリックのほか、尾（エコー・残響）は前の曲の続きとして鳴るので、前の曲は切替点で止める
  bool get endsAtCut => cutsHard || this == echoTail || this == reverbTail;

  /// 前の曲そのものの音から作る音を使うか（[TailRenderer]。作れなければ尾なし / 素材の音）
  bool get rendersAudio => this == echoTail || this == reverbTail || this == spinback;
}
