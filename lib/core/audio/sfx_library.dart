/// DJ ミックスの切り替えに重ねる効果音（assets/sfx/ に同梱。出どころは同フォルダの README）。
///
/// 役割ごとに長さ違いを持ち、クロスフェードの長さ（実時間）に合わせて選ぶ。
/// ライザーなど **終わりを切替点に合わせて** 鳴らすものは、長さが分かっている必要がある
/// （ファイル名の `_2s` などと同じ値。MP3 はフレームを数えた実測）。
enum SfxRole {
  /// 切替点に向けて上がっていく音（終わりを切替点に合わせる）
  riser,

  /// 切替点に向けて吸い込むシンバル（終わりを切替点に合わせる。1 小節に伸び縮み）
  reverseCymbal,

  /// 切替点の瞬間の一撃と余韻（切替点で鳴らし始める）
  impact,

  /// 次の曲の 1 拍目に重ねるシンバル（切替点で鳴らし始める）
  crash,

  /// レコードを逆回転させて巻き取る音（終わりを切替点に合わせる）。
  /// 前の曲から作ったもの（[SfxClip.rendered]）があればそれ、無ければ素材
  spinback,

  /// 前の曲の最後から作った尾（エコー・残響）。切替点で鳴らし始める。素材は無い
  tail;

  /// 切替点で鳴らし始めるもの（それ以外は終わりを切替点に合わせる）
  bool get startsAtCut => this == impact || this == crash || this == tail;
}

class SfxClip {
  const SfxClip(this.role, this.asset, this.durationMs, {this.gainDb = 0})
      : path = null;

  /// アプリが前の曲から作った音（端末内の WAV）。曲の続きとして曲と同じ音量で鳴らす
  const SfxClip.rendered(this.role, String this.path, this.durationMs)
      : asset = path,
        gainDb = 0;

  final SfxRole role;

  /// Flutter のアセットキー（pubspec の assets/sfx/ 以下）。作った音ならファイルのパス
  final String asset;

  /// 作った音のファイル（素材なら null）
  final String? path;
  final int durationMs;

  /// 効果音の音量の設定からさらに足す量（dB）。控えめに重ねる素材はマイナス
  final double gainDb;

  /// 前の曲から作った音か（効果音の音量ではなく曲の音量で鳴らす）
  bool get isRendered => path != null;

  /// media_kit に渡す URI（asset:// はアプリ内のファイルへ展開される）
  String get uri => path ?? 'asset:///$asset';

  @override
  String toString() => 'SfxClip(${asset.split('/').last} ${durationMs}ms)';
}

class SfxLibrary {
  SfxLibrary._();

  static const _dir = 'assets/sfx';

  /// ライザーは同じ長さに何種類かあり、切り替えごとに [pick] の variant で回す
  static const clips = <SfxClip>[
    SfxClip(SfxRole.riser, '$_dir/riser_noise_2s.wav', 2000),
    SfxClip(SfxRole.riser, '$_dir/riser_snare_2s.wav', 2000),
    SfxClip(SfxRole.riser, '$_dir/riser_reverse_crash_2s.wav', 2000),
    SfxClip(SfxRole.riser, '$_dir/riser_noise_4s.wav', 4000),
    SfxClip(SfxRole.riser, '$_dir/riser_sweep_4s.wav', 4000),
    SfxClip(SfxRole.riser, '$_dir/riser_snare_4s.wav', 4000),
    SfxClip(SfxRole.riser, '$_dir/riser_supersaw_4s.wav', 4000),
    SfxClip(SfxRole.riser, '$_dir/riser_noise_8s.wav', 8000),
    SfxClip(SfxRole.riser, '$_dir/riser_sweep_8s.wav', 8000),
    SfxClip(SfxRole.riser, '$_dir/riser_supersaw_8s.wav', 8000),
    // 控えめに重ねるシンバル（大きなライザーより目立たないよう、効果音の音量からさらに下げる）
    SfxClip(SfxRole.reverseCymbal, '$_dir/reverse_cymbal.mp3', 2040, gainDb: -2),
    SfxClip(SfxRole.crash, '$_dir/crash.mp3', 3264, gainDb: -4),
    // インパクトはライザーと同じ形式（44.1kHz / 16bit / モノラル WAV）のものを使う。
    // ライザーの直後にプレイリストで続けて鳴らすとき、形式が同じだとギャップレスになる
    SfxClip(SfxRole.impact, '$_dir/down_impact_tail_2s.wav', 2000),
    SfxClip(SfxRole.spinback, '$_dir/spinback.mp3', 2736),
  ];

  static List<SfxClip> of(SfxRole role) =>
      clips.where((c) => c.role == role).toList(growable: false);

  /// 窓より少し長いのは許す（4 拍 = 1.9 秒の窓に 2 秒のライザーを使う）
  static const overshoot = 1.15;

  /// 鳴らせる窓（実時間ミリ秒）に収まる最も長いものを選ぶ。
  /// どれも収まらなければ最も短いもの。同じ長さの候補は [variant] で順に回す
  static SfxClip pick(SfxRole role, {required int windowMs, int variant = 0}) {
    final candidates = of(role);
    assert(candidates.isNotEmpty, 'no clip for $role');
    final limit = windowMs * overshoot;
    var fitting = candidates.where((c) => c.durationMs <= limit).toList();
    if (fitting.isEmpty) {
      final shortest = candidates.map((c) => c.durationMs).reduce((a, b) => a < b ? a : b);
      fitting = candidates.where((c) => c.durationMs == shortest).toList();
    } else {
      final longest = fitting.map((c) => c.durationMs).reduce((a, b) => a > b ? a : b);
      fitting = fitting.where((c) => c.durationMs == longest).toList();
    }
    return fitting[variant.abs() % fitting.length];
  }
}
