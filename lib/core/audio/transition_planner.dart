import '../../models/loop_item.dart';
import 'band_swap.dart';
import 'crossfade_curve.dart';
import 'track_compatibility.dart';
import 'transition_effect.dart';

/// つなぎ方 1 回分の材料（クロスフェードの長さ・曲線・低音・演出・合わせるか）。
/// 手動の設定をまとめたものと、おまかせ（[TransitionPlanner]）が選んだものの両方をこれで表す
class TransitionRecipe {
  const TransitionRecipe({
    required this.beats,
    required this.curve,
    required this.bands,
    required this.effect,
    required this.beatMatch,
    required this.tempoMatch,
    this.name = '',
    this.reason = '',
    this.auto = false,
    this.style,
    this.sfxDb = 0,
  });

  /// クロスフェードの長さ（拍）。0 = オフ
  final int beats;
  final CrossfadeCurve curve;

  /// 帯域の入れ替え（低音だけ / 高・中・低）
  final BandSwap bands;
  final TransitionEffect effect;
  final bool beatMatch;
  final bool tempoMatch;

  /// おまかせが選んだレシピの名前と理由（手動なら空）
  final String name;
  final String reason;
  final bool auto;

  /// ガチのタイプ（同じタイプが続かないように次の選択で見る）。ガチ以外は null
  final MixStyle? style;

  /// 効果音の音量の上乗せ（dB、マイナスで小さく）。設定の音量に足す
  final int sfxDb;

  /// 低音を入れ替えるか（[bands] が「なし」以外）
  bool get bassSwap => bands != BandSwap.none;

  /// 実際に使う音量曲線。切替点で前の曲を止める演出（トリック・尾）はカット
  CrossfadeCurve get effectiveCurve => effect.endsAtCut ? CrossfadeCurve.cut : curve;

  /// 実際に使う帯域の入れ替え。切替点で前の曲を止める演出では入れ替えない
  BandSwap get effectiveBands => effect.endsAtCut ? BandSwap.none : bands;

  /// ミックスビューに出す 1 行。例「ドロップ合わせ（テンポ差 2% · ドロップ +11dB）」
  String get summary => reason.isEmpty ? name : '$name（$reason）';

  TransitionRecipe copyWith({int? beats, String? reason}) => TransitionRecipe(
        beats: beats ?? this.beats,
        curve: curve,
        bands: bands,
        effect: effect,
        beatMatch: beatMatch,
        tempoMatch: tempoMatch,
        name: name,
        reason: reason ?? this.reason,
        auto: auto,
        style: style,
        sfxDb: sfxDb,
      );

  @override
  String toString() => 'TransitionRecipe($beats拍 ${curve.name} bands=${bands.name} '
      '${effect.name} beat=$beatMatch tempo=$tempoMatch $summary)';
}

/// ガチのつなぎのタイプ
enum MixStyle {
  /// 溶かす: 長く重ね、いつ変わったか分からないように
  melt('溶かす'),

  /// 盛り上げる: 次の曲の立ち上がりに向けて上げる（効果音はたまに、控えめに）
  lift('盛り上げ'),

  /// テンポが合わないので、前の曲を止める・刻むで切り替える
  cut('切り替え');

  const MixStyle(this.label);
  final String label;
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

  /// ガチ: なじませるつなぎの長さ（拍。32 拍 = 8 小節 = 1 フレーズ）
  static const proLongBeats = 32;

  /// ガチ: 歌が重なりそうとみなす中音の平均（前の曲の終わりと次の曲の始まりの両方）。
  /// 中音にはギターなども入るので目安。**実曲で見て調整する値**。
  /// 歌が重なりそうな組は、高・中・低の 3 つの帯域をずらして入れ替える（中音 = 歌の受け渡し）
  static const vocalMid = 0.6;

  /// ガチ: キーが合わない組は、重ねる長さをここまで縮める
  static const keyClashProBeats = 8;

  /// ガチ: 効果音を設定の音量からさらに下げる量（dB）。曲の切り替わりを効果音で
  /// 塗りつぶさない（「大きくして紛らわせてるだけ」に聞こえた）
  static const proSfxDb = -4;

  /// 長さの設定（[CrossfadeNotifier] の拍数）がこれを超えると、おまかせの長いつなぎを伸ばす
  static const stretchBaseBeats = 32;

  /// 伸ばすのはこの拍数以上のつなぎだけ（短く切り替える・ドロップ合わせ・キーや歌が
  /// ぶつかる組は、わざと短くしているので伸ばさない）
  static const stretchMinBeats = 16;

  /// おまかせのつなぎを、長さの設定に合わせて伸ばす。設定が 64 拍なら 2 倍、128 拍なら 4 倍
  /// （溶かす 32 → 64 / 128、ブレンド 16 → 32 / 64）。32 拍以下の設定では変えない
  static TransitionRecipe stretch(TransitionRecipe recipe, int settingBeats) {
    final scale = settingBeats ~/ stretchBaseBeats;
    if (scale <= 1 || recipe.beats < stretchMinBeats) return recipe;
    return recipe.copyWith(beats: recipe.beats * scale);
  }

  /// つなぎが曲に対して長すぎるとき、収まるまで半分にする（フレーズの区切りは保つ）。
  /// [maxMs] は重ねてよい長さ。[minBeats] より短くはしない
  static int fitBeats(int beats, double beatMs, double maxMs, {int minBeats = 4}) {
    var b = beats;
    while (b > minBeats && b * beatMs > maxMs) {
      b ~/= 2;
    }
    return b;
  }

  /// [pro] はガチ。[outTailMid] / [inHeadMid] は前の曲の終わり・次の曲の始まりの
  /// 中音の平均（帯域の波形から。無ければ null で歌のぶつかりは見ない）。
  /// [lastStyle] は直前のつなぎのタイプ（ガチで同じタイプが続かないように）、
  /// [seed] は曲の組ごとに決まる数（同じ組なら何度呼んでも同じ結果。ばらつきに使う）。
  /// [outAtMs] / [inAtMs] は重なる位置（前の曲の切断点・次の曲の入り口）。テンポが途中で
  /// 変わる曲はその位置の区切りのテンポと格子で決める（null なら曲全体の値）
  static TransitionRecipe plan(LoopItem out, LoopItem next,
      {bool pro = false,
      double? outTailMid,
      double? inHeadMid,
      double? outAtMs,
      double? inAtMs,
      MixStyle? lastStyle,
      int seed = 0}) {
    final outBpm = out.bpmAt(outAtMs);
    final inBpm = next.bpmAt(inAtMs);
    final tempoDiff = TrackCompatibility.tempoDiffPercent(outBpm, inBpm);
    final ratio = TrackCompatibility.tempoRatio(outBpm, inBpm);
    // 入る曲が出る曲よりどれだけ速いか（%、倍/半は折り畳む）
    final faster = ratio == null ? null : (1 / ratio - 1) * 100;
    final outGrid = out.beatGridAt(outAtMs);
    final inGrid = next.beatGridAt(inAtMs);
    final live = (outGrid != null && !outGrid.reliable) || (inGrid != null && !inGrid.reliable);
    final energy = next.headDb != null && out.tailDb != null ? next.headDb! - out.tailDb! : null;
    final drop = next.mixInMs == null ? null : next.dropDb;
    final quiet = out.tailDb != null &&
        next.headDb != null &&
        out.tailDb! < quietDb &&
        next.headDb! < quietDb;
    final fadesOut = out.endFadeDb != null && out.endFadeDb! <= fadeOutDb;
    final keyClash = out.endKey != null &&
        next.startKey != null &&
        TrackCompatibility.keyScore(out.endKey, next.startKey) == 0;

    final facts = <String>[
      if (tempoDiff != null) 'テンポ差 ${tempoDiff.round()}%',
    ];
    if (pro && !quiet && !live && tempoDiff != null) {
      return _planPro(
        facts: facts,
        tempoDiff: tempoDiff,
        faster: faster,
        energy: energy,
        drop: drop,
        fadesOut: fadesOut,
        keyClash: keyClash,
        vocalClash: outTailMid != null &&
            inHeadMid != null &&
            outTailMid >= vocalMid &&
            inHeadMid >= vocalMid,
        lastStyle: lastStyle,
        seed: seed,
      );
    }
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
          bass: true, effect: TransitionEffect.filterSweep, match: true);
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

  /// ガチ: テンポが分かっていて拍が安定した 2 曲を、溶かす・盛り上げ・切り替えから選ぶ。
  ///
  /// 1. 曲の組み合わせで候補を絞る（盛り上がる組は盛り上げ、そうでなければ溶かす。
  ///    キーが合わない組は長く重ねられないので溶かすを外す。歌がぶつかる組は
  ///    高・中・低の帯域をずらして入れ替える）
  /// 2. 直前と同じタイプなら、ほかの候補に替える
  static TransitionRecipe _planPro({
    required List<String> facts,
    required double tempoDiff,
    required double? faster,
    required double? energy,
    required double? drop,
    required bool fadesOut,
    required bool keyClash,
    required bool vocalClash,
    required MixStyle? lastStyle,
    required int seed,
  }) {
    TransitionRecipe done(TransitionRecipe r) => r.copyWith(reason: facts.join(' · '));

    // テンポが合わない: 前の曲を止める（ブレーキ）か刻む（ループロール）で切り替える
    if (tempoDiff > tempoLimitPercent) {
      final brake = seed.isEven;
      return done(_make(brake ? 'ブレーキで切り替え' : 'ループロールで切り替え', 4,
          CrossfadeCurve.equalPower,
          bass: false,
          effect: brake ? TransitionEffect.brake : TransitionEffect.loopRoll,
          match: false,
          style: MixStyle.cut));
    }

    final strongDrop = drop != null && drop >= strongDropDb;
    final up = strongDrop ||
        (faster ?? 0) >= fasterPercent ||
        (energy ?? 0) >= energyStepDb;
    // 歌のぶつかりは中音の入れ替えで避けられるので、長く重ねてよい。キーのぶつかりは避けられない
    final canMelt = !keyClash;

    final candidates = <MixStyle>[
      if (up) MixStyle.lift,
      if (canMelt) MixStyle.melt,
      if (!up) MixStyle.lift,
    ];
    var style = candidates.first;
    if (style == lastStyle) {
      style = candidates.firstWhere((c) => c != lastStyle, orElse: () => style);
    }

    if (keyClash) facts.add('キー不一致');
    // 歌が重なりそうなら中音も入れ替える（2 つの歌が同時に前に出ない）
    if (vocalClash) facts.add('歌は中音で入れ替え');
    final bands = vocalClash ? BandSwap.three : BandSwap.bass;
    switch (style) {
      case MixStyle.melt:
        if (fadesOut) facts.add('フェードアウト');
        return done(_make('溶かす', proLongBeats, CrossfadeCurve.melt,
            bass: true,
            bands: bands,
            effect: TransitionEffect.none,
            match: true,
            style: style));
      case MixStyle.lift || MixStyle.cut:
        // 効果音は 2 回に 1 回くらい。鳴らさない回はこもらせて抜くだけ
        final sfx = seed % 3 != 1;
        if (strongDrop) {
          facts.add('ドロップ +${drop.round()}dB');
          return done(_make('ドロップ合わせ', 8, CrossfadeCurve.cut,
              bass: true,
              effect: sfx ? TransitionEffect.riserImpact : TransitionEffect.filterSweep,
              match: true,
              style: MixStyle.lift,
              sfxDb: proSfxDb));
        }
        if (up) facts.add(_energyFact(faster, energy, up: true));
        // キーがぶつかる組は短く入れ替える
        final beats = canMelt ? 16 : keyClashProBeats;
        return done(_make(up ? '盛り上げ' : '入れ替え', beats, CrossfadeCurve.nextFirst,
            bass: true,
            bands: bands,
            effect: up && sfx ? TransitionEffect.riser : TransitionEffect.filterSweep,
            match: true,
            style: MixStyle.lift,
            sfxDb: proSfxDb));
    }
  }

  static String _energyFact(double? faster, double? energy, {required bool up}) {
    if (faster != null && (up ? faster >= fasterPercent : faster <= -fasterPercent)) {
      return '入る曲が${up ? '速い' : '遅い'}';
    }
    final e = energy ?? 0;
    return '入る曲が ${e >= 0 ? '+' : ''}${e.round()}dB';
  }

  static TransitionRecipe _make(String name, int beats, CrossfadeCurve curve,
          {required bool bass,
          BandSwap? bands,
          required TransitionEffect effect,
          required bool match,
          MixStyle? style,
          int sfxDb = 0}) =>
      TransitionRecipe(
        beats: beats,
        curve: curve,
        bands: bass ? (bands ?? BandSwap.bass) : BandSwap.none,
        effect: effect,
        beatMatch: match,
        tempoMatch: match,
        name: name,
        auto: true,
        style: style,
        sfxDb: sfxDb,
      );

  /// 曲の組から決まる数（[plan] の seed）。同じ組なら起動し直しても同じ
  static int seedFor(String outId, String inId) {
    var h = 17;
    for (final c in '$outId>$inId'.codeUnits) {
      h = (h * 31 + c) & 0x3fffffff;
    }
    return h;
  }
}
