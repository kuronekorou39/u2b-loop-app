import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_item.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../loop/loop_seekbar.dart';
import 'mix_view.dart';

/// 下部コントローラーのシーク領域。
/// ふだんは [LoopSeekbar]（bar モード）、曲の切り替わりが近づくと [MixView] に変わる。
///
/// 重ね表示は [PlaylistEngine.mixPair]（1 曲目と 2 曲目をつないだ 1 本の時間軸）を
/// そのまま描く。出すか出さないかは、実際の再生位置をその時間軸に写した値が
/// 窓（交差の前後）の中かどうかで決め、時間で勝手に閉じない。
/// 切り替わった後も、前曲が準備線まで残っている間は「ミックス」で戻って来られる
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

  /// ミックスビューの高さ（2 段ぶん）
  final double mixHeight;

  /// 曲の波形（プリロード時に先行生成したもの）。無ければ null
  final List<double>? Function(LoopItem item) waveformFor;
  final String Function(LoopItem item) titleFor;

  @override
  ConsumerState<PlaylistSeekArea> createState() => _PlaylistSeekAreaState();
}

class _PlaylistSeekAreaState extends ConsumerState<PlaylistSeekArea> {
  /// 「ミックス」ボタンで重ね表示に戻った（再生位置が窓の外でも出し続ける）
  bool _forceMix = false;

  /// 重ね表示の窓（見えている範囲、出る曲の時計）。「−」「＋」「交差」「全体」や
  /// ミニマップで変わる。[_pairKey] の組が変わったら最初の窓に戻す
  MixWindow? _window;
  String? _pairKey;

  /// 重ね表示でシークした先（出る曲の時計）と時刻。シーク直後の再生位置は少しの間
  /// 古い値を返すので、それで判定すると一瞬ふつうのシークバーに戻ってチラつく。
  /// その間はシーク先を使う
  Duration? _seekTarget;
  DateTime? _seekAt;
  static const _seekHold = Duration(milliseconds: 800);

  Duration _displayPosition(Duration now) {
    final at = _seekAt;
    if (at != null && DateTime.now().difference(at) < _seekHold) {
      return _seekTarget ?? now;
    }
    _seekAt = null;
    _seekTarget = null;
    return now;
  }

  void _holdAt(Duration target) {
    _seekTarget = target;
    _seekAt = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final slot = ref.watch(activeSlotProvider);
    // 位置の更新で描き直すためだけに見る。値は下でプレイヤーから直接取る
    ref.watch(positionProvider);

    final engine = ref.read(playlistEngineProvider);
    final pair = engine.mixPair();
    if (pair == null) {
      _forceMix = false;
      _window = null;
      _pairKey = null;
      return _seekbar();
    }
    final timelineEnd = _timelineEnd(pair);
    if (pair.key != _pairKey) {
      _forceMix = false;
      _pairKey = pair.key;
      _window = null;
    }
    final window = _window ??= MixView.initialWindow(
        start: pair.start, cut: pair.cut, timelineEnd: timelineEnd);

    // 再生位置は鳴っている側のプレイヤーから直接読む。positionProvider はスロットが
    // 切り替わった直後、作り直されるまで前のプレイヤーの値を返すので、それを入る曲の
    // 時計として換算すると窓の外に飛び、一瞬ふつうのシークバーに戻ってしまう
    final swapped = slot != pair.outSlot;
    final position = ref.read(_playerOf(slot)).state.position;
    final now = _displayPosition(swapped ? pair.toOutClock(position) : position);
    // 出す条件: 切替点の前後（最初の窓）に再生位置があるか、自分で広げた窓の中にあるか
    final nearCut =
        now >= pair.start - MixView.lead && now <= pair.cut + MixView.tail;
    if (_forceMix || nearCut || window.contains(now)) {
      return _mix(pair, now, window, timelineEnd, swapped: swapped);
    }
    // 切り替わった後（前曲が残っている間）は、重ね表示に戻れる
    if (!swapped) return _seekbar();
    return _seekbar(
      trailing: _BackToMixChip(
        onTap: () => setState(() => _forceMix = true),
      ),
    );
  }

  /// 時間軸の終わり: 2 曲目の終わりを出る曲の時計に直したもの。
  /// 長さがまだ分からなければ、最初の窓の右端まで
  static Duration _timelineEnd(MixPair pair) {
    final end = pair.inDuration > Duration.zero
        ? pair.toOutClock(pair.inDuration)
        : pair.cut + MixView.tail;
    final least = pair.cut + MixView.minSpanFloor;
    return end < least ? least : end;
  }

  static ProviderBase<Player> _playerOf(ActiveSlot slot) =>
      slot == ActiveSlot.a ? playerAProvider : playerBProvider;

  Widget _seekbar({Widget? trailing}) => LoopSeekbar(
        compact: widget.compact,
        bar: true,
        barHeight: widget.waveHeight,
        onToggleCompact: widget.onToggleCompact,
        allowMarkerDrag: false,
        onRetryWaveform: widget.onRetryWaveform,
        trailing: trailing,
      );

  Widget _mix(MixPair pair, Duration now, MixWindow window, Duration timelineEnd,
      {required bool swapped}) {
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
    return MixView(
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
      timelineEnd: timelineEnd,
      onWindowChanged: (w) => setState(() => _window = w),
      prepLine: pair.prepLine,
      height: widget.mixHeight,
      curve: recipe.curve,
      bassSwap: recipe.bassSwap,
      note: recipe.auto ? 'おまかせ: ${recipe.summary}' : null,
      onSeek: (t) => _seekInMix(pair, t, swapped: swapped),
    );
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
      _holdAt(target);
      onReplayPrevious(target);
      return;
    }
    _holdAt(t);
    ref.read(playlistEngineProvider).seekInPair(pair, t);
  }

  static Duration _clamp(Duration d, Duration max) {
    if (d < Duration.zero) return Duration.zero;
    if (max > Duration.zero && d > max) return max;
    return d;
  }
}

/// ふつうのシークバーを出している間、重ね表示に戻るボタン
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
