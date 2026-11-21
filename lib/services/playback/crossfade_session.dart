part of 'playlist_engine.dart';

/// 拍合わせ 1 回分の材料
class _BeatPlan {
  const _BeatPlan({
    required this.outGrid,
    required this.inGrid,
    required this.outBars,
    required this.inBars,
    required this.outRate,
    required this.inRate,
    required this.lock,
  });

  final BeatGrid outGrid;
  final BeatGrid inGrid;

  /// 小節の格子（重ね始めの位置合わせ用。交差中のナッジは拍の格子で）
  final BeatGrid outBars;
  final BeatGrid inBars;
  final double outRate;
  final double inRate;

  /// 交差中も位相を測って速度で合わせ続けるか（実効テンポが揃っているときだけ）
  final bool lock;
}

/// クロスフェード1回分。開始時の旧プレイヤーの音量を交差後の目標にする
class _CrossfadeSession {
  _CrossfadeSession({
    required this.recipe,
    required this.outPlayer,
    required this.inPlayer,
    required this.start,
    required this.cut,
    required this.advancesAtCut,
    required this.volume,
    required this.inVolume,
    required this.inStart,
    required this.inBaseRate,
    required this.inMatchedRate,
    required this.inRate,
    required this.curve,
    required this.bands,
    required this.effect,
    required this.beat,
    required this.swapStartMs,
    required this.swapEndMs,
    required this.midStartMs,
    required this.midEndMs,
    required this.highStartMs,
    required this.highEndMs,
    required this.openEndMs,
    required this.outRate,
    required this.beatRealMs,
    required this.beatMediaMs,
    required this.sfx,
    required this.sfxPlan,
    required this.sfxVolume,
    required this.sfxOffsetMs,
    required this.onForceCut,
    required double jogMs,
  })  : outVolume = volume,
        appliedInRate = inRate,
        _jogMs = jogMs;

  /// 帯域の入れ替え 1 つにかける拍数（DJ の「一動作」。ゆっくり交差させない）
  static const bassSwapBeats = 2;

  /// この交差のつなぎ方（開始時に決めたもの。途中で設定が変わっても使い続ける）
  final TransitionRecipe recipe;

  /// 交差開始時の出る曲の速度。ブレーキで落とした後はこれに戻す
  final double outRate;

  /// 出る曲の 1 拍（実時間 / 媒体のミリ秒）
  final double beatRealMs;
  final double beatMediaMs;

  /// 効果音（使わない演出なら null）と、その音量（0〜100 の尺度）
  final TransitionSfx? sfx;
  final double sfxVolume;

  /// 効果音の予定（いつ・どれを・どの速度で）。重ね表示にも出す
  final SfxPlan? sfxPlan;

  /// 効果音のタイミングの補正（実時間 ms、+ で遅く）。設定で耳に合わせる分
  final int sfxOffsetMs;

  /// ライザーを伸び縮みさせたとき、続くインパクトのためにこの時間だけ前に素の速度へ戻す
  /// （ライザーの最後がわずかに速く／遅く鳴るだけ）
  static const rateResetLeadMs = 40;

  /// トリックの終わりに切替点を待たずに遷移を起こす
  final void Function(_CrossfadeSession) onForceCut;

  // --- トリック（実時間のタイマーで進める） ---

  /// ブレーキの長さ（拍）と、実時間での下限・上限
  static const brakeBeats = 2;
  static const brakeMinMs = 700;
  static const brakeMaxMs = 2500;

  /// ブレーキの終わりの速度（mpv の下限 0.01 より上。ほぼ止まった低い唸り）
  static const brakeMinRate = 0.05;

  /// ループロールは最後の 1 小節。(始まる拍, ループの長さ(拍))
  static const loopRollBeats = 4;
  static const loopRollStages = [(0.0, 1.0), (2.0, 0.5), (3.0, 0.25), (3.5, 0.125)];

  final _timers = <Timer>[];
  Timer? _brakeTimer;
  bool _tricksStarted = false;

  /// トリック中の出る曲の音量比（null = 曲線のまま）
  double? _outOverride;

  /// 切替点の瞬間に実時間のタイマーで切り替えた（以後は出る曲 0・入る曲 1）。
  /// 100ms ごとの監視を待つと、尾と前の曲が重なったり次の曲の頭が欠けたりする
  bool _cutFired = false;

  /// 効果音とトリックを予定する。[wallToCutMs] は切替点までの実時間
  void startTricks({required int wallToCutMs}) {
    if (_tricksStarted) return;
    _tricksStarted = true;
    final toCut = max(0, wallToCutMs);
    final s = sfx;
    final plan = sfxPlan;
    if (s != null && plan != null) {
      // 効果音は切替点からの相対で予定する（[SfxPlan] が出る曲の時計で決めた位置を実時間に）。
      // 音が出るまでの遅れの分だけ前倒し、設定の補正を足す
      final cutMs = cut.inMicroseconds / 1000;
      final latency = TransitionSfx.startLatencyMs.round();
      final lead = plan.lead;
      if (lead != null) {
        final leadRealMs = ((cutMs - lead.atMs) / outRate).round();
        _after(toCut - leadRealMs - latency + sfxOffsetMs, () {
          unawaited(s.start(volume: _volumeOf(lead.clip), rate: lead.rate));
          // スピンバックはレコードを巻き取る音なので、曲はすぐ消す。曲そのものから作った
          // 逆回転は曲の止めた所から始まるので、重なりを短く
          if (effect == TransitionEffect.spinback) {
            lead.clip.isRendered ? _killOut(steps: 2, stepMs: 30) : _killOut();
          }
        });
        // 伸び縮みさせたライザーに続けて鳴るインパクトは素の速度で
        if (lead.rate != 1 && plan.impact != null) {
          _after(toCut - rateResetLeadMs + sfxOffsetMs, () => unawaited(s.setRate(1)));
        }
      } else if (plan.impact != null) {
        // インパクト単独も切替点に合わせて予定する。以前は実際の切り替え（スワップ）で鳴らして
        // いたが、スワップは曲の終わりの検出や 100ms ごとの監視を待つので遅れ、前の曲が
        // 終わってから鳴っていた
        _after(toCut - latency + sfxOffsetMs, _fireImpact);
      }
    }
    // 切替点で前の曲を止める演出のうち、位置が切替点まで普通に進むもの（尾・スピンバック）は
    // 実時間で切り替える（尾は前の曲の続きとして鳴るので、前の曲が残ると二重に聞こえる）
    if (effect.endsAtCut && effect != TransitionEffect.brake &&
        effect != TransitionEffect.loopRoll) {
      _after(toCut - TransitionSfx.startLatencyMs.round() + sfxOffsetMs, _cutNow);
    }
    switch (effect) {
      case TransitionEffect.brake:
        final durMs =
            (beatRealMs * brakeBeats).round().clamp(brakeMinMs, brakeMaxMs);
        _after(toCut - durMs, () => _startBrake(durMs));
      case TransitionEffect.loopRoll:
        _after(toCut - (beatRealMs * loopRollBeats).round(), _startLoopRoll);
      default:
        break;
    }
  }

  void _after(int ms, void Function() fn) {
    _timers.add(Timer(Duration(milliseconds: max(0, ms)), fn));
  }

  void _setOut(double level) {
    _outOverride = level.clamp(0.0, 1.0);
    outVolume = volume * _outOverride!;
    outPlayer.setVolume(outVolume);
  }

  /// 出る曲を [steps] × [stepMs] で消す（既定 200ms）
  void _killOut({int steps = 4, int stepMs = 50}) {
    for (var i = 1; i <= steps; i++) {
      _after(i * stepMs, () => _setOut(1 - i / steps));
    }
  }

  /// 切替点: 出る曲を止めて入る曲を全開に（以後の [step] もこのまま）
  void _cutNow() {
    _cutFired = true;
    _setOut(0);
    inPlayer.setVolume(inVolume);
  }

  /// 効果音の音量。曲から作った音は曲の続きなので曲と同じ大きさ、素材は効果音の音量に
  /// 素材ごとの控えめさ（[SfxClip.gainDb]）を足す
  double _volumeOf(SfxClip clip) {
    if (clip.isRendered) return volume;
    if (clip.gainDb == 0) return sfxVolume;
    return sfxVolume * pow(10, clip.gainDb / 20);
  }

  /// ブレーキ: 速度をほぼ一定の減速で落とす（レコードが止まる動き）。音程も一緒に落ちる。
  /// 音量は最後の 3 割で落とし、止まったら切替点を待たずに次の曲へ
  void _startBrake(int durMs) {
    unawaited(DeckTricks.setPitchCorrection(outPlayer, false));
    final t0 = DateTime.now();
    _brakeTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      final x = DateTime.now().difference(t0).inMilliseconds / durMs;
      if (x >= 1) {
        timer.cancel();
        _setOut(0);
        onForceCut(this);
        return;
      }
      unawaited(outPlayer.setRate(outRate * max(brakeMinRate, 1 - x)));
      if (x > 0.7) _setOut((1 - x) / 0.3);
    });
  }

  /// ループロール: 切替点の 1 小節前から、同じ始点で 1 → 1/2 → 1/4 → 1/8 拍のループを
  /// 刻む（mpv の AB ループ）。小節が終わったら切替点を待たずに次の曲へ
  void _startLoopRoll() {
    final cutMs = cut.inMicroseconds / 1000;
    final aMs = max(start.inMicroseconds / 1000, cutMs - beatMediaMs * loopRollBeats);
    for (final (atBeat, lenBeats) in loopRollStages) {
      _after((atBeat * beatRealMs).round(), () {
        unawaited(DeckTricks.setAbLoop(outPlayer, aMs, aMs + lenBeats * beatMediaMs));
      });
    }
    _after((loopRollBeats * beatRealMs).round(), () {
      _setOut(0);
      unawaited(DeckTricks.clearAbLoop(outPlayer));
      onForceCut(this);
    });
  }

  void _cancelTricks() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _brakeTimer?.cancel();
    _brakeTimer = null;
  }

  /// 切替点（スワップ）で呼ぶ。まだ待っていた効果音・トリックは捨て、
  /// 切替点の瞬間の効果音（インパクト単独）を鳴らす。ライザーの後のインパクトは
  /// プレイリストで続けて鳴る
  void onCut() {
    _cancelTricks();
    // 予定より早く切り替わった（重ね表示で切替点より後を押した・トリックで切った）ときだけ、ここで鳴らす
    if (effect.impactAtCut && effect.leadInSfx == null) _fireImpact();
  }

  bool _impactFired = false;

  /// 切替点で鳴らす音（インパクト・クラッシュ・尾）を 1 回だけ鳴らす
  void _fireImpact() {
    if (_impactFired) return;
    _impactFired = true;
    final clip = sfxPlan?.impact?.clip;
    unawaited(sfx?.start(volume: clip == null ? sfxVolume : _volumeOf(clip)));
  }

  /// 低音の入れ替えの開始・終了位置（出る曲の媒体ミリ秒）。開始は拍の頭に寄せてある。
  /// 演出（スイープ）も開始位置から切替点にかけて
  final double swapStartMs;
  final double swapEndMs;

  /// 3 帯域のとき: 中音・高音の入れ替えの開始・終了位置（低音より前。高音 → 中音 → 低音）
  final double midStartMs;
  final double midEndMs;
  final double highStartMs;
  final double highEndMs;

  /// フィルターインで入る曲が開き切る位置
  final double openEndMs;

  /// 拍合わせの計画（しないときは null）
  final _BeatPlan? beat;

  /// 直近に入る曲へ設定した速度（テンポ合わせ + ナッジ）。交差後はここから本来の速度へ戻す
  double appliedInRate;

  /// ジョグで動かした量（入る曲の媒体ミリ秒）。[applyJog] が差分だけ入る曲をシークする。
  /// 交差を始めたときの量から数える（開始位置にはもう入っているので、二重に効かせない）
  double _jogMs;

  /// 重なって鳴っている入る曲を [u] へ動かす（下の棒でのシーク）。測定は少し待つ
  void seekIn(Duration u) {
    unawaited(inPlayer.seek(u));
    _nudgeHoldUntil = DateTime.now().add(const Duration(milliseconds: 400));
  }

  /// 手でジョグを回している間は自動ナッジ（速度の寄せ）を止める。ずれの測定は続ける
  bool jogging = false;

  /// ジョグを音に効かせる。[jogMs] は絶対量。前回との差だけ入る曲をシークする
  void applyJog(double jogMs, {required bool touching}) {
    jogging = touching;
    final delta = jogMs - _jogMs;
    _jogMs = jogMs;
    if (delta.abs() < 1) return;
    final pos = inPlayer.state.position;
    unawaited(inPlayer.seek(pos + Duration(microseconds: (delta * 1000).round())));
    // シーク直後の位置は信用できないので少し測定を待つ
    _nudgeHoldUntil = DateTime.now().add(const Duration(milliseconds: 250));
  }

  /// 保存したので、動かした量を基準に戻す（音は動かさない）
  void acceptJog() {
    _jogMs = 0;
    jogging = false;
  }

  double _errSmooth = 0;
  int _nudgeTicks = 0;
  bool _measuring = false;
  DateTime? _nudgeHoldUntil;
  DateTime? _settleUntil;

  /// [resync] の直後で、出る曲の位置の報告がまだ信用できない間
  bool get settling {
    final until = _settleUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// 出る曲を交差の中の [outPos] へ動かしたとき、入る曲も同じ時間軸の位置に合わせる。
  /// 出る曲の媒体時間 1ms あたり、入る曲の媒体時間が進む量（テンポ合わせで速度が違う）
  double get inRatio => outRate > 0 ? inRate / outRate : 1;

  /// 拍合わせは測り直す（シークが済むまでの位置は信用できないので少し待つ）
  void resync(Duration outPos) {
    final offset = outPos - start;
    unawaited(inPlayer.seek(
        offset > Duration.zero ? inStart + offset * inRatio : inStart));
    _measuring = false;
    _nudgeTicks = 0;
    _errSmooth = 0;
    final now = DateTime.now();
    _nudgeHoldUntil = now.add(const Duration(milliseconds: 400));
    _settleUntil = now.add(const Duration(seconds: 1));
    if (appliedInRate != inRate) {
      appliedInRate = inRate;
      unawaited(inPlayer.setRate(inRate));
    }
  }

  /// 交差中の拍合わせ: 両プレイヤーの位置から位相のずれを測り、入る曲の速度で寄せる。
  /// play() 直後は位置が動き出すまで待つ（開始遅延はこの測定で吸収される）。
  /// 戻り値は測ったずれ（平滑後、実時間 ms）。測れないときは null。
  /// テンポが揃わず合わせ続けない組（lock でない）も、ずれは測って返す（寄せはしない）
  double? nudgeBeats(Duration outPos) {
    final plan = beat;
    // トリック中は出る曲の位置が遅くなる・戻るので、位相を測っても意味がない
    if (plan == null || effect.cutsHard) return null;
    final hold = _nudgeHoldUntil;
    if (hold != null && DateTime.now().isBefore(hold)) return null;
    final inPos = inPlayer.state.position;
    if (!_measuring) {
      if (inPos <= inStart) return null;
      _measuring = true;
    }
    final err = BeatMatcher.phaseErrorMs(
      out: plan.outGrid,
      in_: plan.inGrid,
      outPosMs: outPos.inMicroseconds / 1000,
      outRate: plan.outRate,
      inPosMs: inPos.inMicroseconds / 1000,
      inRate: appliedInRate,
    );
    // 位置の報告は粗いので半分ずつ平滑化してから使う
    _errSmooth = _nudgeTicks == 0 ? err : 0.5 * _errSmooth + 0.5 * err;
    _nudgeTicks++;
    if (!plan.lock || jogging) return _errSmooth;
    final target = inRate * (1 + BeatMatcher.rateAdjust(_errSmooth));
    if ((target - appliedInRate).abs() >= 0.0005) {
      appliedInRate = target;
      unawaited(inPlayer.setRate(target));
    }
    if (_nudgeTicks % 10 == 1) {
      debugPrint('[BeatMatch] 位相誤差 ${err.toStringAsFixed(0)}ms '
          '(平滑 ${_errSmooth.toStringAsFixed(0)}ms) → rate ${target.toStringAsFixed(4)}');
    }
    return _errSmooth;
  }

  /// つなぎ方（音量曲線）。開始時の設定を交差の間は使い続ける。
  /// 切替点で前の曲を止める演出ならカット（[TransitionRecipe.effectiveCurve]）
  final CrossfadeCurve curve;

  /// 帯域の入れ替え。開始時に入る曲の低音（3 帯域なら中音も）を切り、
  /// 高音 → 中音 → 低音（[CrossfadeCurve.bassSwapAt]）の順に出る曲の帯域を切って入る曲の帯域を戻す
  final BandSwap bands;

  /// 出る曲にかける演出。ベーススワップと同じ位置から切替点までかける
  final TransitionEffect effect;

  final Player outPlayer;
  final Player inPlayer;
  final Duration start;
  final Duration cut;

  /// 切断点が曲の終端より手前（曲末の無音を飛ばす）なので、到達時に遷移を起こす
  final bool advancesAtCut;
  bool advanced = false;

  final double volume;

  /// 入る曲の交差後の音量（音量正規化で出る曲と違うことがある）
  final double inVolume;

  /// 取り消し時に新プレイヤーを戻す位置（次曲のA点）
  final Duration inStart;

  /// 次曲本来の速度と、交差中にテンポを寄せた速度（寄せないときは同じ値）
  final double inBaseRate;

  /// テンポ合わせで決めた入る曲の速度（手の微調整を除く）。微調整はこれに掛ける
  double inMatchedRate;

  /// 入る曲の目標速度（テンポ合わせ × 微調整）。ナッジはこの周りで寄せる
  double inRate;

  /// ピッチフェーダーを音に効かせる。[factor] はテンポ合わせの速度に掛ける比
  void applyTempoTrim(double factor) {
    final next = inMatchedRate * factor;
    if ((next - inRate).abs() < 0.0005) return;
    inRate = next;
    appliedInRate = next;
    unawaited(inPlayer.setRate(next));
  }

  /// テンポを保存したので、今の速度を基準に戻す（音は動かさない）
  void acceptTempo() {
    inMatchedRate = inRate;
  }

  /// 直近に旧プレイヤーへ設定した音量（スワップ時に残っていれば短く落とす）
  double outVolume;

  /// 音量を交差させ、進捗（0〜1）を返す
  double step(Duration pos) {
    final total = (cut - start).inMilliseconds;
    final t = total <= 0
        ? 1.0
        : ((pos - start).inMilliseconds / total).clamp(0.0, 1.0);
    // 切替点で前の曲を止める演出は、曲線がカット（[curve]）。トリックが音量を握っていれば
    // それに従い、実時間で切り替えた後は出る曲 0・入る曲 1
    final levels = _cutFired ? (out: 0.0, in_: 1.0) : curve.levels(t);
    outVolume = volume * (_outOverride ?? levels.out);
    outPlayer.setVolume(outVolume);
    inPlayer.setVolume(inVolume * levels.in_);

    final posMs = pos.inMicroseconds / 1000;
    final cutMs = cut.inMicroseconds / 1000;
    if (t >= 1) return t;
    // 区間 [from, to] の中の進み（0〜1）
    double ramp(double from, double to) =>
        to > from ? ((posMs - from) / (to - from)).clamp(0.0, 1.0) : 1.0;
    // 帯域の入れ替え: 拍の頭から 2 拍かけて、出る曲の帯域を切りつつ入る曲の帯域を戻す
    // （フィルタは付けっぱなしで値だけ動かすので音は途切れない）。
    // 3 帯域は高音（出る曲だけ抜く。入る曲のハイハットは最初から）→ 中音 → 低音の順
    if (bands == BandSwap.three) {
      if (posMs >= highStartMs) {
        unawaited(AudioFilters.setHighDb(
            outPlayer, AudioFilters.bandDb(ramp(highStartMs, highEndMs))));
      }
      if (posMs >= midStartMs) {
        final r = ramp(midStartMs, midEndMs);
        unawaited(AudioFilters.setMidDb(outPlayer, AudioFilters.bandDb(r)));
        unawaited(AudioFilters.setMidDb(inPlayer, AudioFilters.bandDb(1 - r)));
      }
    }
    if (bands != BandSwap.none && posMs >= swapStartMs && swapEndMs > swapStartMs) {
      final r = ramp(swapStartMs, swapEndMs);
      unawaited(AudioFilters.setBassDb(outPlayer, AudioFilters.bassDb(r)));
      unawaited(AudioFilters.setBassDb(inPlayer, AudioFilters.bassDb(1 - r)));
    }
    // スイープ: スワップの位置から切替点にかけてローパスを閉じていく
    if (effect.sweepsOut && posMs >= swapStartMs && cutMs > swapStartMs) {
      unawaited(AudioFilters.setSweep(outPlayer,
          AudioFilters.sweepHz((posMs - swapStartMs) / (cutMs - swapStartMs))));
    }
    // フィルターイン: 交差の始めから低音が入る所にかけて、入る曲を開いていく
    if (effect.sweepsIn) {
      final startMs = start.inMicroseconds / 1000;
      unawaited(AudioFilters.setSweep(
          inPlayer, AudioFilters.sweepHz(1 - ramp(startMs, openEndMs))));
    }
    return t;
  }

  /// 入る曲のフィルタを触ったか（交差の後・取り消しで初期値に戻す）
  bool get _touchesIn => bands != BandSwap.none || effect.sweepsIn;

  /// 切断点で呼ぶ（旧プレイヤーは停止済み）。
  /// 旧プレイヤーを音量0のままにすると、次にプリロード側として再利用されたとき無音になる
  void finish() {
    finishIn();
    outPlayer.setVolume(volume);
    clearOut(keepFilters: false);
  }

  /// 新プレイヤーだけ本来の音量に戻す（旧プレイヤーは別途落としてから戻す）。
  /// 低音が戻り切っていなければ戻す（ランプの途中でスワップが来た場合）
  void finishIn() {
    inPlayer.setVolume(inVolume);
    if (_touchesIn) unawaited(AudioFilters.reset(inPlayer));
  }

  /// 出る曲のトリックを初期状態に戻す（次にプリロード側として使うため）。
  /// [keepFilters] は出る曲をまだ使うとき（パークして戻れる・交差の取り消しで鳴り続ける）:
  /// フィルタの値を初期に戻す（戻さないと低音・中音・高音が切れたまま、こもったまま鳴る）。
  /// 止めたプレイヤーなら値は戻さず状態だけ忘れる（次に開く前の detach で外れる）
  void clearOut({required bool keepFilters}) {
    _cancelTricks();
    if (keepFilters) {
      unawaited(AudioFilters.reset(outPlayer));
    } else {
      AudioFilters.forget(outPlayer);
    }
    unawaited(DeckTricks.reset(outPlayer));
    if (effect == TransitionEffect.brake) unawaited(outPlayer.setRate(outRate));
  }

  /// 取り消し。新プレイヤーを頭に戻して待機状態へ。効果音も止める
  void rollback() {
    _cancelTricks();
    unawaited(sfx?.stop());
    inPlayer.pause();
    inPlayer.seek(inStart);
    inPlayer.setVolume(inVolume);
    if (appliedInRate != inBaseRate) inPlayer.setRate(inBaseRate);
    outPlayer.setVolume(volume);
    if (_touchesIn) unawaited(AudioFilters.reset(inPlayer));
    // 出る曲は鳴り続けるので、途中まで切った帯域を戻す
    clearOut(keepFilters: true);
  }
}
