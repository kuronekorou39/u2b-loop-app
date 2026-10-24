import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/audio/track_compatibility.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_snack_bar.dart';
import '../../models/loop_item.dart';
import '../../providers/loop_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../loop/loop_seekbar.dart';
import 'jog_wheel.dart';
import 'mix_deck.dart';
import 'mix_lanes_advance.dart';
import 'mix_view.dart';

/// 下部コントローラーのシーク領域。
/// ふだんは [LoopSeekbar]（bar モード）。曲の切り替わりが近づくと重ね表示になり、
/// 上から「前曲の細い棒」「重ねの帯（[MixView]）」「次曲の細い棒」「時刻行（次曲）」。
/// 前曲の棒で 1 曲目の序盤へ戻れ、次曲の棒で 2 曲目の中を動ける。
/// 高さはふつうの表示（波形 + 棒 + 時刻行）と同じに揃えて、切り替わっても下部が動かない。
/// 時刻行の左のボタン（ふつうの表示でも同じ場所）でデッキの板（[MixDeck]: 円盤 2 つと
/// ピッチフェーダー）を開閉する。板は帯に重ねず、この領域の上（コントローラーの上。動画や
/// 曲名に被さる）に浮かせて出す（[OverlayPortal]。帯の上に重ねると波形が見えなくなり、
/// 操作もかぶる）。
///
/// 重ね表示は [PlaylistEngine] の組（[MixPair]: 1 曲目と 2 曲目をつないだ 1 本の時間軸）を
/// そのまま描く。出すか出さないかは、実際の再生位置をその時間軸に写した値が
/// 「出す範囲」（交差の前後に [triggerMarginFor] の余白）の中かどうかだけで決める。
/// **デッキを開いている間は範囲の外でも重ね表示のまま**（毎回ボタンを押さなくていい。
/// 組は自然に切り替える: 出す範囲の中の組があればそれ、無ければ予定の次曲との組、
/// それも無ければ前曲との組。組がまったく無いときだけふつうのシークバー）。
/// 帯に描く範囲（窓 = 交差の前後に [_margin]）はそれより狭く、「−」「＋」で変える。
/// 出す範囲を広く取るので、帯が出た時点では再生位置がまだ窓の左外のことがある
/// （位置は上下の棒で分かる。その間に円盤で合わせられる）。
/// 外ではふつうのシークバーに、出す範囲を紫で塗る:
/// 曲の頭側に前の曲とのぶん、終わり側に次の曲とのぶん
class PlaylistSeekArea extends ConsumerStatefulWidget {
  const PlaylistSeekArea({
    super.key,
    required this.compact,
    required this.onToggleCompact,
    required this.onRetryWaveform,
    this.onReplayPrevious,
    required this.waveformFor,
    required this.titleFor,
    this.waveHeight = 72,
    this.mixHeight = 72,
  });

  final bool compact;
  final VoidCallback onToggleCompact;
  final VoidCallback onRetryWaveform;

  /// 切り替わった後に前曲側（切替点より前）を押したとき、
  /// 前の曲に戻ってその位置から聴き直す。null なら戻れない
  final ValueChanged<Duration>? onReplayPrevious;

  /// 波形シークバーの高さ（compact でないとき）
  final double waveHeight;

  /// 重ね表示の帯の置き場の高さ。前曲の棒と隙間をここから取り、残りが帯
  /// （ふつうの表示の波形の高さと同じにしておくと、切り替わっても下部が動かない）
  final double mixHeight;

  /// 曲の波形（プリロード時に先行生成したもの）。無ければ null
  final List<double>? Function(LoopItem item) waveformFor;
  final String Function(LoopItem item) titleFor;

  /// 出す範囲の余白は帯の窓の余白の何倍か（ユーザー: 2.5 倍くらい）
  static const triggerScale = 2.5;

  /// 出す範囲の余白の下限。窓を一番狭くしても、これだけ手前から帯を出す
  static const minTriggerMargin = Duration(seconds: 10);

  /// 帯の窓の余白 [margin] に対する、重ね表示を出す範囲の余白
  static Duration triggerMarginFor(Duration margin) {
    final scaled = margin * triggerScale;
    return scaled < minTriggerMargin ? minTriggerMargin : scaled;
  }

  /// 前曲の棒の高さ（次曲の棒より細く。帯との隙間は [AppSpacing.xs]）
  static const topBarHeight = 20.0;

  /// ふつうの波形と重ね表示の行き来はフェード（一瞬で入れ替えない。時刻行の開閉ボタンは
  /// 両方の同じ場所にあるので動いて見えない）。組が次へ進むときは [MixLanesAdvance]
  static const fadeDuration = Duration(milliseconds: 250);

  @override
  ConsumerState<PlaylistSeekArea> createState() => _PlaylistSeekAreaState();
}

class _PlaylistSeekAreaState extends ConsumerState<PlaylistSeekArea> {
  /// 帯に描く範囲の余白。「−」「＋」で段を変える。曲が変わっても持ち越す
  Duration _margin = MixView.defaultMargin;

  /// デッキの板を出しているか（時刻行の左のボタン。既定は出さない）。
  /// 出している間は出す範囲の外でも重ね表示を続ける
  bool _wheelsOpen = false;

  /// 板をこの領域の上に浮かせる（この領域の上端に板の下端を合わせる）
  final _link = LayerLink();
  final _deckPortal = OverlayPortalController();

  /// この領域の幅（板の幅に使う。描画後に分かるので 1 フレーム遅れる）
  double _width = 0;

  /// 今の build で重ね表示を出しているなら、板に渡す材料。出していなければ null
  _DeckData? _deckData;

  /// 重ね表示でシークした先（出る曲の時計）と時刻、どの組か。シーク直後の再生位置は
  /// 少しの間古い値を返すので、それで判定すると一瞬ふつうのシークバーに戻ってチラつく。
  /// その間はシーク先を使う
  Duration? _seekTarget;
  DateTime? _seekAt;
  String? _seekPairKey;
  static const _seekHold = Duration(milliseconds: 800);

  Duration _displayPosition(MixPair pair, Duration now) {
    final at = _seekAt;
    if (at != null && DateTime.now().difference(at) < _seekHold) {
      return _seekPairKey == pair.key ? _seekTarget ?? now : now;
    }
    _seekAt = null;
    _seekTarget = null;
    _seekPairKey = null;
    return now;
  }

  void _holdAt(MixPair pair, Duration target) {
    _seekTarget = target;
    _seekAt = DateTime.now();
    _seekPairKey = pair.key;
  }

  @override
  Widget build(BuildContext context) {
    _deckData = null;
    final body = _body();
    return OverlayPortal(
      controller: _deckPortal,
      overlayChildBuilder: _buildDeck,
      child: CompositedTransformTarget(
        link: _link,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _width = constraints.maxWidth;
            return AnimatedSwitcher(
              duration: PlaylistSeekArea.fadeDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: body,
            );
          },
        ),
      ),
    );
  }

  void _toggleDeck() {
    setState(() {
      _wheelsOpen = !_wheelsOpen;
      if (_wheelsOpen) {
        _deckPortal.show();
      } else {
        _deckPortal.hide();
      }
    });
  }

  Widget _body() {
    final slot = ref.watch(activeSlotProvider);
    // 位置の更新で描き直すためだけに見る。値は下でプレイヤーから直接取る
    ref.watch(positionProvider);
    // 組の開始位置はジョグを含むので、回している間は組を作り直す。
    // テンポの微調整も板に出す値なので、動かしたらすぐ描き直す
    ref.watch(jogOffsetProvider);
    ref.watch(tempoTrimProvider);

    final engine = ref.read(playlistEngineProvider);
    // パーク中の前曲との組（切り替わった後）と、予定の次曲との組（切り替わる前）。
    // 同じ曲でも頭側と終わり側で別の組になる
    final parked = engine.parkedPair;
    final planned = engine.plannedPair();
    final pairs = [
      ?parked,
      if (planned != null && planned.key != parked?.key) planned,
    ];
    if (pairs.isEmpty) return _seekbar();

    // 再生位置は鳴っている側のプレイヤーから直接読む。positionProvider はスロットが
    // 切り替わった直後、作り直されるまで前のプレイヤーの値を返すので、それを入る曲の
    // 時計として換算すると窓の外に飛び、一瞬ふつうのシークバーに戻ってしまう
    final position = ref.read(_playerOf(slot)).state.position;
    final ranges = [
      for (final pair in pairs)
        _rangeOf(_triggerOf(pair), pair, swapped: slot != pair.outSlot),
    ];
    for (final pair in pairs) {
      final swapped = slot != pair.outSlot;
      final now =
          _displayPosition(pair, swapped ? pair.toOutClock(position) : position);
      if (_triggerOf(pair).contains(now)) {
        return _mix(pair, now, _windowOf(pair),
            swapped: swapped, position: position);
      }
    }
    if (_wheelsOpen) {
      // デッキを開いている間は範囲の外でも重ね表示。予定の次曲との組を優先
      // （前曲との組は切り替わった直後に戻るためのもの）
      final pair = planned ?? pairs.first;
      final swapped = slot != pair.outSlot;
      final now =
          _displayPosition(pair, swapped ? pair.toOutClock(position) : position);
      return _mix(pair, now, _windowOf(pair),
          swapped: swapped, position: position);
    }
    return _seekbar(mixRanges: ranges);
  }

  /// デッキの開閉ボタン。ふつうの表示でも重ね表示でも時刻行の左の同じ場所
  Widget _deckButton() => IconButton(
        icon: Icon(_wheelsOpen ? Icons.album : Icons.album_outlined,
            size: AppIconSizes.sm),
        tooltip: _wheelsOpen ? 'デッキを閉じる' : 'デッキを出す',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        visualDensity: VisualDensity.compact,
        color: _wheelsOpen ? AppTheme.accentGreen : null,
        onPressed: _toggleDeck,
      );

  /// 出す範囲（出る曲の時計）を鳴っている曲の時計に直したもの（細いバーの紫の塗り）
  static MixRange _rangeOf(MixWindow window, MixPair pair,
          {required bool swapped}) =>
      swapped
          ? (start: pair.toInClock(window.start), end: pair.toInClock(window.end))
          : (start: window.start, end: window.end);

  /// 帯に描く範囲（窓）
  MixWindow _windowOf(MixPair pair) => MixView.windowAround(
        start: pair.start,
        cut: pair.cut,
        margin: _margin,
        timelineEnd: _timelineEnd(pair),
      );

  /// 重ね表示を出す範囲（窓より広い）
  MixWindow _triggerOf(MixPair pair) => MixView.windowAround(
        start: pair.start,
        cut: pair.cut,
        margin: PlaylistSeekArea.triggerMarginFor(_margin),
        timelineEnd: _timelineEnd(pair),
      );

  /// 時間軸の終わり: 2 曲目の終わりを出る曲の時計に直したもの。
  /// 長さがまだ分からなければ、切替点から余白ぶん
  static Duration _timelineEnd(MixPair pair) {
    final end = pair.inDuration > Duration.zero
        ? pair.toOutClock(pair.inDuration)
        : pair.cut + MixView.margins.last;
    final least = pair.cut + MixView.minSpanFloor;
    return end < least ? least : end;
  }

  static ProviderBase<Player> _playerOf(ActiveSlot slot) =>
      slotPlayerProvider(slot);

  Widget _seekbar({
    List<MixRange> mixRanges = const [],
    ({VoidCallback? wider, VoidCallback? narrower})? zoom,
  }) =>
      LoopSeekbar(
        key: const ValueKey('bar'),
        compact: widget.compact || zoom != null,
        bar: true,
        barHeight: widget.waveHeight,
        onToggleCompact: widget.onToggleCompact,
        allowMarkerDrag: false,
        onRetryWaveform: widget.onRetryWaveform,
        mixRanges: mixRanges,
        zoom: zoom,
        timeRowLeading: _deckButton(),
      );

  Widget _mix(MixPair pair, Duration now, MixWindow window,
      {required bool swapped, required Duration position}) {
    final narrower = MixView.narrower(_margin);
    final wider = MixView.wider(_margin);
    final zoom = (
      wider: wider == null ? null : () => setState(() => _margin = wider),
      narrower:
          narrower == null ? null : () => setState(() => _margin = narrower),
    );
    final trigger = _triggerOf(pair);
    // 閉じているときは帯を出さない（細いバーの紫の塗りで範囲は分かる）
    if (widget.compact) {
      return _seekbar(
          mixRanges: [_rangeOf(trigger, pair, swapped: swapped)], zoom: zoom);
    }

    final engine = ref.read(playlistEngineProvider);
    final current = ref.watch(waveformDataProvider);
    final outItem = pair.outItem;
    final inItem = pair.next.item;
    // 鳴っている側の波形は waveformDataProvider（生成し立てでも届く）、もう片方は先読み分
    final outWaveform = swapped
        ? (outItem == null ? null : widget.waveformFor(outItem))
        : current ?? (outItem == null ? null : widget.waveformFor(outItem));
    final inWaveform =
        swapped ? current ?? widget.waveformFor(inItem) : widget.waveformFor(inItem);
    final recipe = pair.recipe;
    final showBeats = ref.watch(showBeatLinesProvider);
    final loop = ref.watch(loopProvider);
    // 交差中か（次曲の棒でのシークは、交差中か切り替わった後だけ効く）
    final crossfading = ref.watch(crossfadeProgressProvider) != null;

    // 次曲の位置: 切り替わった後は鳴っている曲、前は先読み側（交差の前は開始位置で止まっている）
    final inPosition =
        swapped ? position : engine.preloadPlayer.state.position;
    // 前曲の位置: 切り替わった後は切替点で止まっている
    final outPosition = swapped ? pair.cut : now;

    final bandHeight =
        widget.mixHeight - PlaylistSeekArea.topBarHeight - AppSpacing.xs;
    final band = MixView(
      outWaveform: outWaveform,
      outDuration: pair.outDuration,
      outTitle: outItem == null ? '' : widget.titleFor(outItem),
      inWaveform: inWaveform,
      inDuration: pair.inDuration,
      inStart: pair.inStart,
      inTitle: widget.titleFor(inItem),
      start: pair.start,
      cut: pair.cut,
      now: now,
      swapped: swapped,
      window: window,
      height: bandHeight,
      curve: recipe.curve,
      bassSwap: recipe.bassSwap,
      outBeats: showBeats ? outItem?.beatLines : null,
      inBeats: showBeats ? inItem.beatLines : null,
      inRatio: pair.inRatio,
      // 交差の間だけ測れる（切り替わった後・交差の前は出さない）
      beatError: showBeats ? ref.watch(beatPhaseErrorProvider) : null,
      sfxCues: pair.sfx?.cues ?? const [],
      onSeek: (t) => _seekInMix(pair, t, swapped: swapped),
    );
    _deckData = (
      pair: pair,
      swapped: swapped,
      outPosition: outPosition,
      inPosition: inPosition,
    );

    // 棒 2 本と帯は組ごと。組が次へ進んだら 3 拍子で入れ替える（前曲の段が左へ抜け、
    // 次曲の段が上がり、新しい次曲の段が右から）。時刻行は外に置いて動かさない（開閉ボタンの場所）
    final lanes = MixLanesAdvance(
      pairKey: ValueKey(pair.key),
      topBarHeight: PlaylistSeekArea.topBarHeight,
      bandHeight: bandHeight,
      bottomBarHeight: ThinSeekbar.defaultHeight,
      // 前曲の棒。切り替わった後に押せば前の曲に戻って聴き直す
      topBar: ThinSeekbar(
        position: outPosition,
        duration: pair.outDuration,
        height: PlaylistSeekArea.topBarHeight,
        mixRanges: [(start: trigger.start, end: trigger.end)],
        pointA: swapped ? null : loop.pointA,
        pointB: swapped ? null : loop.pointB,
        loopEnabled: !swapped && loop.enabled,
        onSeek: (t) => _seekInMix(pair, t, swapped: swapped),
      ),
      band: band,
      // 次曲の棒
      bottomBar: ThinSeekbar(
        position: inPosition,
        duration: pair.inDuration,
        mixRanges: [
          (
            start: pair.toInClock(trigger.start),
            end: pair.toInClock(trigger.end)
          ),
        ],
        pointA: swapped ? loop.pointA : null,
        pointB: swapped ? loop.pointB : null,
        loopEnabled: swapped && loop.enabled,
        onSeek: swapped || crossfading
            ? (u) {
                ref.read(jogOffsetProvider.notifier).state = null;
                engine.seekInTrack(pair, u);
              }
            : null,
      ),
    );

    return Padding(
      key: const ValueKey('mix'),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Column(
        children: [
          lanes,
          SeekTimeRow(
            position: inPosition,
            duration: pair.inDuration,
            onToggleCompact: widget.onToggleCompact,
            zoom: zoom,
            leading: _deckButton(),
          ),
        ],
      ),
    );
  }

  /// デッキの板（この領域の上に浮かせる）。重ね表示を出していないときは空。
  /// 左（前曲）は再生に合わせて回るだけ、右（次曲）は回して拍の位置を、
  /// フェーダーでテンポを合わせる。切り替わった後は右も回るだけ
  Widget _buildDeck(BuildContext portalContext) {
    final data = _deckData;
    if (data == null || _width <= 0) return const SizedBox.shrink();
    final pair = data.pair;
    final swapped = data.swapped;
    final engine = ref.read(playlistEngineProvider);
    final inItem = pair.next.item;
    final grid = inItem.beatGrid;
    final jogMax = swapped ? null : engine.jogMaxMs(pair);
    final jogMs = engine.jogMsFor(pair.next);
    final trim = engine.tempoTrimFor(pair.next);
    final canTrim = !swapped && grid != null;
    final touched = jogMs.abs() >= 1 || trim != 0;

    void setJog(double ms, {required bool touching}) {
      ref.read(jogOffsetProvider.notifier).state = (key: pair.key, ms: ms);
      engine.jog(pair, ms, touching: touching);
    }

    void setTrim(double percent) {
      ref.read(tempoTrimProvider.notifier).state =
          (key: pair.key, percent: percent);
      engine.trimTempo(pair, percent);
    }

    void clear() {
      ref.read(jogOffsetProvider.notifier).state = null;
      ref.read(tempoTrimProvider.notifier).state = null;
    }

    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -MixDeck.liftAbove),
        child: MixDeck(
          width: _width,
          contentKey: ValueKey(pair.key),
          outTurns: JogWheel.platterTurns(data.outPosition),
          inTurns: swapped ? JogWheel.platterTurns(data.inPosition) : 0,
          outBpm: engine.outTempoBpm(pair),
          inBpm: engine.inTempoBpm(pair),
          jog: jogMax == null
              ? null
              : (
                  periodMs: grid?.periodMs ?? 500.0,
                  valueMs: jogMs,
                  maxMs: jogMax,
                  errorMs: engine.jogErrorMs(pair),
                ),
          tempo: canTrim
              ? (
                  percent: trim,
                  maxPercent: TrackCompatibility.maxTempoAdjustPercent,
                )
              : null,
          onJog: setJog,
          onJogEnd: (ms) => setJog(ms, touching: false),
          onTempo: setTrim,
          onTempoEnd: setTrim,
          onReset: !touched
              ? null
              : () {
                  clear();
                  engine.jog(pair, 0, touching: false);
                  engine.trimTempo(pair, 0);
                },
          onSave: !touched
              ? null
              : () async {
                  if (jogMs.abs() >= 1) await engine.saveJog(pair, jogMs);
                  if (trim != 0) await engine.saveTempo(pair, trim);
                  clear();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      AppSnackBar.success('この曲の拍を直しました'));
                },
        ),
      ),
    );
  }

  /// 帯・前曲の棒でのシーク。[t] は出る曲の時計。
  /// 切り替わった後に切替点より前を押したら前の曲に戻って聴き直す
  /// （[PlaylistSeekArea.onReplayPrevious]。前曲はパークしてあるので開き直さない）。
  /// それ以外は [PlaylistEngine.seekInPair]（交差の中なら両方を合わせ、
  /// 切替点より後ならその場で切り替える）
  void _seekInMix(MixPair pair, Duration t, {required bool swapped}) {
    if (swapped && t < pair.cut) {
      final onReplayPrevious = widget.onReplayPrevious;
      if (onReplayPrevious == null) return;
      final target = _clamp(t, pair.outDuration);
      _holdAt(pair, target);
      onReplayPrevious(target);
      return;
    }
    _holdAt(pair, t);
    ref.read(playlistEngineProvider).seekInPair(pair, t);
  }

  static Duration _clamp(Duration d, Duration max) {
    if (d < Duration.zero) return Duration.zero;
    if (max > Duration.zero && d > max) return max;
    return d;
  }
}

/// デッキの板に渡す材料（重ね表示を出している組と、両方の曲の位置）
typedef _DeckData = ({
  MixPair pair,
  bool swapped,
  Duration outPosition,
  Duration inPosition,
});
