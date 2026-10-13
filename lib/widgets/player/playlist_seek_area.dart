import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  });

  final bool compact;
  final VoidCallback onToggleCompact;
  final VoidCallback onRetryWaveform;

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
    final position =
        ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final engine = ref.read(playlistEngineProvider);

    final swappedAt = _swappedAt;
    if (swappedAt != null) {
      final snap = _snapshot!;
      // 切り替わり後: 新曲の位置を旧曲の時計に換算して、しばらく見せる
      final now = snap.start + (position - snap.inStart);
      if (now <= snap.cut + MixView.tail &&
          DateTime.now().difference(swappedAt) < MixView.tail * 2) {
        return _mix(snap, now, swapped: true);
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
      );
      _snapshot = snap;
      return _mix(snap, position, swapped: false);
    }
    _snapshot = null;

    return LoopSeekbar(
      compact: widget.compact,
      bar: true,
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
    );
  }
}
