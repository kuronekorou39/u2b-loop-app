import 'dart:math';

import 'sfx_library.dart';
import 'transition_effect.dart';

/// 効果音 1 つの予定: 出る曲の時計で「いつから鳴らすか」と、どの素材をどの速度で
class SfxCue {
  const SfxCue({
    required this.clip,
    required this.atMs,
    this.rate = 1,
    this.bars = 0,
  });

  final SfxClip clip;

  /// 鳴らし始める位置（出る曲の媒体ミリ秒）
  final double atMs;

  /// 再生速度（ライザーを小節数にぴったり収めるために伸び縮みさせる。1 = そのまま）
  final double rate;

  /// 小節数（拍に合わせたライザー。合わせていなければ 0）
  final int bars;

  SfxRole get role => clip.role;

  @override
  String toString() => 'SfxCue(${clip.asset.split('/').last} '
      '@${atMs.round()}ms ×${rate.toStringAsFixed(2)}'
      '${bars > 0 ? ' $bars小節' : ''})';
}

/// 演出の効果音の予定（純粋関数）。
///
/// DJ の定石どおり小節で数える:
/// - ライザーは切替点の 1 / 2 / 4 / 8 小節前の小節頭から始め、素材（2 / 4 / 8 秒）の
///   再生速度を変えてその小節数にぴったり収める。頂点が切替点（新しい段落の「1」）に来る
/// - インパクトは切替点で鳴らす
/// - スピンバックは素材の長さのまま、終わりを切替点に合わせる（巻き取る音なので伸ばさない）
///
/// 拍の格子が無い曲は従来どおり（交差の長さに収まる長さの素材を 1 倍速で、終わりを切替点に）
class SfxPlan {
  const SfxPlan(this.cues);

  /// 鳴らす順
  final List<SfxCue> cues;

  /// 切替点の手前で鳴らすもの（ライザー / スピンバック）
  SfxCue? get lead =>
      cues.where((c) => c.role != SfxRole.impact).firstOrNull;

  /// 切替点で鳴らすもの
  SfxCue? get impact =>
      cues.where((c) => c.role == SfxRole.impact).firstOrNull;

  List<SfxClip> get clips => [for (final c in cues) c.clip];

  bool get isEmpty => cues.isEmpty;

  /// ライザーの小節数の候補（長いものから試す）。交差の中に収まるものだけ使う
  static const riserBars = [8, 4, 2, 1];

  /// 素材を伸び縮みさせてよい速度の範囲（外れると音が変わりすぎるので小節数を減らす）
  static const minRate = 0.5;
  static const maxRate = 2.0;

  /// [effect] の効果音を予定する。[startMs] / [cutMs] は交差の開始と切替点（出る曲の媒体ミリ秒）、
  /// [outRate] は出る曲の再生速度、[barMediaMs] は出る曲の 1 小節（格子が無ければ null）。
  /// 同じ長さの素材が何本かあるときは [variant] で順に回す
  static SfxPlan plan({
    required TransitionEffect effect,
    required double startMs,
    required double cutMs,
    required double outRate,
    double? barMediaMs,
    int variant = 0,
  }) {
    final rate = outRate > 0 ? outRate : 1.0;
    final windowMs = max(0.0, (cutMs - startMs) / rate).round();
    final cues = <SfxCue>[];
    final lead = effect.leadInSfx;
    if (lead == SfxRole.riser && barMediaMs != null && barMediaMs > 0) {
      cues.add(_riser(
          startMs: startMs,
          cutMs: cutMs,
          outRate: rate,
          barMediaMs: barMediaMs,
          windowMs: windowMs,
          variant: variant));
    } else if (lead != null) {
      final clip = SfxLibrary.pick(lead, windowMs: windowMs, variant: variant);
      cues.add(SfxCue(clip: clip, atMs: cutMs - clip.durationMs * rate));
    }
    if (effect.impactAtCut) {
      cues.add(SfxCue(
          clip: SfxLibrary.pick(SfxRole.impact,
              windowMs: windowMs, variant: variant),
          atMs: cutMs));
    }
    return SfxPlan(cues);
  }

  static SfxCue _riser({
    required double startMs,
    required double cutMs,
    required double outRate,
    required double barMediaMs,
    required int windowMs,
    required int variant,
  }) {
    final candidates = SfxLibrary.of(SfxRole.riser);
    for (final bars in riserBars) {
      final mediaMs = bars * barMediaMs;
      // 交差の中に収まる小節数だけ（効果音は交差が始まってから予定するので、
      // それより前からは鳴らせない）
      if (mediaMs > cutMs - startMs + 1) continue;
      final realMs = mediaMs / outRate;
      // 長さの比が一番近い素材
      final best = candidates.reduce((a, b) =>
          log(a.durationMs / realMs).abs() <= log(b.durationMs / realMs).abs()
              ? a
              : b);
      final rate = best.durationMs / realMs;
      if (rate < minRate || rate > maxRate) continue;
      final same = candidates
          .where((c) => c.durationMs == best.durationMs)
          .toList(growable: false);
      return SfxCue(
        clip: same[variant.abs() % same.length],
        atMs: cutMs - mediaMs,
        rate: rate,
        bars: bars,
      );
    }
    final clip =
        SfxLibrary.pick(SfxRole.riser, windowMs: windowMs, variant: variant);
    return SfxCue(clip: clip, atMs: cutMs - clip.durationMs * outRate);
  }
}
