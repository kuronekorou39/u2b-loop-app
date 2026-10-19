import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../models/loop_item.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../loop/loop_seekbar.dart';
import 'mix_view.dart';

/// 下部コントローラーのシーク領域。
/// ふだんは [LoopSeekbar]（bar モード）、曲の切り替わりが近づくと細いバーと時刻行は
/// そのままの位置で、その上に [MixView]（重ねの帯）が足される。時刻行の開閉ボタンの右に
/// 「−」「＋」が出る。閉じれば帯も消えて細いバーと時刻行だけになる
///
/// 重ね表示は [PlaylistEngine] の組（[MixPair]: 1 曲目と 2 曲目をつないだ 1 本の時間軸）を
/// そのまま描く。出すか出さないかは、実際の再生位置をその時間軸に写した値が
/// 窓（交差の前後に [_margin] の余白）の中かどうかだけで決める。
/// 外ではふつうのシークバーに、窓の端（重ね表示に切り替わる位置）を線で印す:
/// 曲の頭側に前の曲との重ね表示の終わり、終わり側に次の曲との重ね表示の始まり。
/// 重ね表示の間も細いバーで窓の外（1 曲目の前半など）へ戻れる
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

  /// 切り替わった後にミックスビューで前曲側（切替点より前）をタップしたとき、
  /// 前の曲に戻ってその位置から聴き直す。null なら戻れない
  final ValueChanged<Duration>? onReplayPrevious;

  /// 波形シークバーの高さ（compact でないとき）
  final double waveHeight;

  /// 重ねの帯の高さ（2 段ぶん）。この下に細いバー 28px と時刻行が付く
  final double mixHeight;

  /// 曲の波形（プリロード時に先行生成したもの）。無ければ null
  final List<double>? Function(LoopItem item) waveformFor;
  final String Function(LoopItem item) titleFor;

  @override
  ConsumerState<PlaylistSeekArea> createState() => _PlaylistSeekAreaState();
}

class _PlaylistSeekAreaState extends ConsumerState<PlaylistSeekArea> {
  /// 交差の前後に付ける余白（重ね表示を出す範囲）。「−」「＋」で段を変える。
  /// 曲が変わっても持ち越す
  Duration _margin = MixView.defaultMargin;

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
    final slot = ref.watch(activeSlotProvider);
    // 位置の更新で描き直すためだけに見る。値は下でプレイヤーから直接取る
    ref.watch(positionProvider);

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
    final lines = <Duration>[];
    for (final pair in pairs) {
      final window = _windowOf(pair);
      final swapped = slot != pair.outSlot;
      final now =
          _displayPosition(pair, swapped ? pair.toOutClock(position) : position);
      if (window.contains(now)) {
        return _mix(pair, now, window,
            swapped: swapped,
            lines: [...lines, ..._linesOf(pair, window, swapped: swapped)]);
      }
      lines.addAll(_linesOf(pair, window, swapped: swapped));
    }
    return _seekbar(mixLines: lines);
  }

  /// 窓の両端を鳴っている曲の時計に直し、曲の中に入るものだけ（線の位置）。
  /// 切り替わる前はふつう窓の始まりだけ、後は窓の終わりだけが曲の中にある
  static List<Duration> _linesOf(MixPair pair, MixWindow window,
      {required bool swapped}) {
    final duration = swapped ? pair.inDuration : pair.outDuration;
    return [
      for (final edge in [window.start, window.end])
        if (swapped ? pair.toInClock(edge) : edge case final t
            when t > Duration.zero &&
                (duration <= Duration.zero || t < duration))
          t,
    ];
  }

  MixWindow _windowOf(MixPair pair) => MixView.windowAround(
        start: pair.start,
        cut: pair.cut,
        margin: _margin,
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
      slot == ActiveSlot.a ? playerAProvider : playerBProvider;

  Widget _seekbar({
    List<Duration> mixLines = const [],
    Widget? above,
    ({VoidCallback? wider, VoidCallback? narrower})? zoom,
  }) =>
      LoopSeekbar(
        // 重ね表示の間は波形の代わりに帯を上に置くので、バーは細いまま
        compact: widget.compact || above != null || zoom != null,
        bar: true,
        barHeight: widget.waveHeight,
        onToggleCompact: widget.onToggleCompact,
        allowMarkerDrag: false,
        onRetryWaveform: widget.onRetryWaveform,
        mixLines: mixLines,
        above: above,
        zoom: zoom,
      );

  Widget _mix(MixPair pair, Duration now, MixWindow window,
      {required bool swapped, required List<Duration> lines}) {
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
    final narrower = MixView.narrower(_margin);
    final wider = MixView.wider(_margin);
    final zoom = (
      wider: wider == null ? null : () => setState(() => _margin = wider),
      narrower:
          narrower == null ? null : () => setState(() => _margin = narrower),
    );
    // 閉じているときは帯を出さない（細いバーの紫の線で範囲は分かる）
    if (widget.compact) return _seekbar(mixLines: lines, zoom: zoom);
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
      prepLine: pair.prepLine,
      height: widget.mixHeight,
      curve: recipe.curve,
      bassSwap: recipe.bassSwap,
      onSeek: (t) => _seekInMix(pair, t, swapped: swapped),
    );
    return _seekbar(mixLines: lines, above: band, zoom: zoom);
  }

  /// ミックスビュー上のシーク。[t] は出る曲の時計。
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
