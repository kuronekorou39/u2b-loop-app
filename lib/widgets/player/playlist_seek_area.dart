import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/transition_planner.dart';
import '../../core/theme/app_theme.dart';
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
  /// 前の曲に戻ってその位置から聴き直す。null なら次曲のシークだけ
  final ValueChanged<Duration>? onReplayPrevious;

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

  /// 重ね表示でシークした先と時刻。シーク直後の再生位置は少しの間古い値を返すので、
  /// それで判定すると一瞬ふつうのシークバーに戻ってチラつく。その間はシーク先を使う
  Duration? _seekTarget;
  DateTime? _seekAt;
  static const _seekHold = Duration(milliseconds: 800);

  /// 重ね表示の代わりに曲全体のシークバーを出している（「全体」ボタン。曲の前のほうへ行くとき）。
  /// 重ね表示が出ない位置まで戻ったら解除する（次に近づいたらまた重ね表示になる）
  bool _showFull = false;

  void _onSlotChanged() {
    if (_snapshot == null) return;
    setState(() => _swappedAt = DateTime.now());
  }

  Duration _displayPosition(Duration raw) {
    final at = _seekAt;
    if (at != null && DateTime.now().difference(at) < _seekHold) {
      return _seekTarget ?? raw;
    }
    _seekAt = null;
    _seekTarget = null;
    return raw;
  }

  void _holdAt(Duration target) {
    _seekTarget = target;
    _seekAt = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeSlotProvider, (_, _) => _onSlotChanged());
    final raw = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final mix = _buildMix(_displayPosition(raw));
    if (mix == null) {
      _showFull = false;
      return _seekbar();
    }
    if (!_showFull) return mix;
    return Stack(
      children: [
        _seekbar(),
        Positioned(
          top: 0,
          right: AppSpacing.xl,
          child: _BackToMixChip(
            onTap: () => setState(() => _showFull = false),
          ),
        ),
      ],
    );
  }

  Widget _seekbar() => LoopSeekbar(
        compact: widget.compact,
        bar: true,
        barHeight: widget.waveHeight,
        onToggleCompact: widget.onToggleCompact,
        allowMarkerDrag: false,
        onRetryWaveform: widget.onRetryWaveform,
      );

  /// 重ね表示を出すならそのウィジェット、出さないなら null
  Widget? _buildMix(Duration position) {
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
    return null;
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
      onShowFull: () => setState(() => _showFull = true),
    );
  }

  /// ミックスビュー上のシーク。[t] は旧曲の時計。
  /// 切り替わる前は旧曲をそのまま動かす（交差の手前へ戻せばエンジンが交差を取り消し、
  /// 切断点を越えれば従来どおり切り替わる）ので、ここで交差を何度でも聴き直せる。
  /// 切り替わった後は、切替点より前をタップしたら前の曲に戻って聴き直し
  /// （[PlaylistSeekArea.onReplayPrevious]。前曲はパークしてあるので開き直さない）、
  /// 切替点より後は次曲の時計で動かしてミックスビューを閉じる
  void _seekInMix(_MixSnapshot snap, Duration t, {required bool swapped}) {
    final player = ref.read(playerProvider);
    if (!swapped) {
      final target = _clamp(t, snap.outDuration);
      _holdAt(target);
      player.seek(target);
      return;
    }
    final onReplayPrevious = widget.onReplayPrevious;
    if (t < snap.cut && onReplayPrevious != null) {
      final target = _clamp(t, snap.outDuration);
      _holdAt(target);
      setState(() {
        _snapshot = null;
        _swappedAt = null;
      });
      onReplayPrevious(target);
      return;
    }
    final pos = _clamp(snap.inStart + (t - snap.start), snap.inDuration);
    _holdAt(pos);
    player.seek(pos);
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

/// 全体のシークバーを出している間、重ね表示に戻るボタン
class _BackToMixChip extends StatelessWidget {
  const _BackToMixChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.swap_horiz,
                  size: AppIconSizes.xs, color: AppTheme.accentGreen),
              const SizedBox(width: AppSpacing.xs),
              Text('ミックス',
                  style: style?.copyWith(color: AppTheme.accentGreen)),
            ],
          ),
        ),
      ),
    );
  }
}
