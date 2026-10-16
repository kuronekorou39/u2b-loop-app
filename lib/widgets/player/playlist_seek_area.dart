import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/transition_planner.dart';
import '../../models/loop_item.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../loop/loop_seekbar.dart';
import 'mix_view.dart';

/// 下部コントローラーのシーク領域。
/// ふだんは [LoopSeekbar]（bar モード）、曲の切り替わりが近づくと [MixView] に変わる。
///
/// 切り替わり後も数秒はミックスビューを出し続けるため、交差の情報は
/// スワップ前にスナップショットとして持っておく（スワップ後はエンジンの予定が消え、
/// 旧曲の波形・長さもプロバイダから無くなる）。
class PlaylistSeekArea extends ConsumerStatefulWidget {
  const PlaylistSeekArea({
    super.key,
    required this.compact,
    required this.onToggleCompact,
    required this.onRetryWaveform,
    required this.waveformFor,
    required this.titleFor,
    this.waveHeight = 72,
    this.mixHeight = 72,
  });

  final bool compact;
  final VoidCallback onToggleCompact;
  final VoidCallback onRetryWaveform;

  /// 波形シークバーの高さ（compact でないとき）
  final double waveHeight;

  /// ミックスビューの高さ（2 段ぶん）
  final double mixHeight;

  /// 次曲の波形（プリロード時に先行生成したもの）。無ければ null
  final List<double>? Function(LoopItem item) waveformFor;
  final String Function(LoopItem item) titleFor;

  @override
  ConsumerState<PlaylistSeekArea> createState() => _PlaylistSeekAreaState();
}

class _MixSnapshot {
  _MixSnapshot({
    required this.outWaveform,
    required this.outDuration,
    required this.outTitle,
    required this.inItem,
    required this.inWaveform,
    required this.inDuration,
    required this.inStart,
    required this.start,
    required this.cut,
    required this.recipe,
  });

  final List<double>? outWaveform;
  final Duration outDuration;
  final String outTitle;
  final LoopItem inItem;
  final List<double>? inWaveform;
  final Duration inDuration;
  final Duration inStart;
  final Duration start;
  final Duration cut;

  /// つなぎ方（曲線・低音の印・おまかせの説明）。スワップ後も同じものを描く
  final TransitionRecipe recipe;
}

class _PlaylistSeekAreaState extends ConsumerState<PlaylistSeekArea> {
  _MixSnapshot? _snapshot;

  /// スワップが起きた時刻（null なら交差前）
  DateTime? _swappedAt;

  void _onSlotChanged() {
    if (_snapshot == null) return;
    setState(() => _swappedAt = DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeSlotProvider, (_, _) => _onSlotChanged());
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final engine = ref.read(playlistEngineProvider);

    final swappedAt = _swappedAt;
    if (swappedAt != null) {
      final snap = _snapshot!;
      // 切り替わり後: 経過時間で再生位置を進める。
      // positionProvider はスワップ直後しばらく旧プレイヤーの最後の位置（≒曲末）を
      // 返すため、それで換算すると一気に窓の外に出てミックスビューが即消えてしまう
      final elapsed = DateTime.now().difference(swappedAt);
      if (elapsed <= MixView.tail) {
        return _mix(snap, snap.cut + elapsed, swapped: true);
      }
      _snapshot = null;
      _swappedAt = null;
    }

    final plan = engine.plannedCrossfade();
    if (plan != null && position >= plan.start - MixView.lead) {
      final outDuration = engine.activePlayer.state.duration;
      final inItem = plan.next.item;
      final current = ref.read(videoSourceProvider);
      final snap = _MixSnapshot(
        outWaveform: ref.watch(waveformDataProvider),
        outDuration: outDuration,
        outTitle: current?.title ?? '',
        inItem: inItem,
        inWaveform: widget.waveformFor(inItem),
        inDuration: engine.preloadPlayer.state.duration,
        inStart: engine.effectiveStart(plan.next),
        start: plan.start,
        cut: plan.cut,
        recipe: plan.recipe,
      );
      _snapshot = snap;
      return _mix(snap, position, swapped: false);
    }
    _snapshot = null;

    return LoopSeekbar(
      compact: widget.compact,
      bar: true,
      barHeight: widget.waveHeight,
      onToggleCompact: widget.onToggleCompact,
      allowMarkerDrag: false,
      onRetryWaveform: widget.onRetryWaveform,
    );
  }

  Widget _mix(_MixSnapshot snap, Duration now, {required bool swapped}) {
    return MixView(
      outWaveform: snap.outWaveform,
      outDuration: snap.outDuration,
      outTitle: snap.outTitle,
      inWaveform: snap.inWaveform,
      inDuration: snap.inDuration,
      inStart: snap.inStart,
      inTitle: widget.titleFor(snap.inItem),
      start: snap.start,
      cut: snap.cut,
      now: now,
      swapped: swapped,
      height: widget.mixHeight,
      curve: snap.recipe.curve,
      bassSwap: snap.recipe.bassSwap,
      note: snap.recipe.auto ? 'おまかせ: ${snap.recipe.summary}' : null,
      onSeek: (t) => _seekInMix(snap, t, swapped: swapped),
    );
  }

  /// ミックスビュー上のシーク。[t] は旧曲の時計。
  /// 切り替わる前は旧曲をそのまま動かす（交差の手前へ戻せばエンジンが交差を取り消し、
  /// 切断点を越えれば従来どおり切り替わる）。
  /// 切り替わった後は旧曲はもう止まっているので、次曲の時計に直して動かし、
  /// ミックスビューは閉じてふつうのシークバーに戻す
  void _seekInMix(_MixSnapshot snap, Duration t, {required bool swapped}) {
    final player = ref.read(playerProvider);
    if (!swapped) {
      player.seek(_clamp(t, snap.outDuration));
      return;
    }
    final pos = snap.inStart + (t - snap.start);
    player.seek(_clamp(pos, snap.inDuration));
    setState(() {
      _snapshot = null;
      _swappedAt = null;
    });
  }

  static Duration _clamp(Duration d, Duration max) {
    if (d < Duration.zero) return Duration.zero;
    if (max > Duration.zero && d > max) return max;
    return d;
  }
}
