import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// 手動の表示切替（「全体」「ミックス」ボタン）
enum _MixDisplay { mix, full }

class _PlaylistSeekAreaState extends ConsumerState<PlaylistSeekArea> {
  /// 手動の表示切替。null なら自動（再生位置が窓の中なら重ね表示）
  _MixDisplay? _override;

  /// [_override] を付けた組。組が変わったら忘れる
  String? _overrideKey;

  /// 重ね表示でシークした先（出る曲の時計）と時刻。シーク直後の再生位置は少しの間
  /// 古い値を返すので、それで判定すると一瞬ふつうのシークバーに戻ってチラつく。
  /// その間はシーク先を使う
  Duration? _seekTarget;
  DateTime? _seekAt;
  static const _seekHold = Duration(milliseconds: 800);

  /// 直近の再生位置。スロットが切り替わった直後、positionProvider は作り直しの
  /// 一瞬だけ値を持たないので、その間はこれを使う
  Duration _lastRaw = Duration.zero;

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
    final raw = ref.watch(positionProvider).valueOrNull;
    if (raw != null) _lastRaw = raw;
    final position = raw ?? _lastRaw;

    final engine = ref.read(playlistEngineProvider);
    final pair = engine.mixPair();
    if (pair == null) {
      _override = null;
      _overrideKey = null;
      return _seekbar();
    }
    if (pair.key != _overrideKey) {
      _override = null;
      _overrideKey = pair.key;
    }

    final swapped = slot != pair.outSlot;
    final now = _displayPosition(swapped ? pair.toOutClock(position) : position);
    final inWindow =
        now >= pair.start - MixView.lead && now <= pair.cut + MixView.tail;
    final showMix = switch (_override) {
      null => inWindow,
      _MixDisplay.mix => true,
      _MixDisplay.full => false,
    };
    if (showMix) return _mix(pair, now, swapped: swapped);
    // 切り替わった後（前曲が残っている間）か「全体」で退けた間は、重ね表示に戻れる
    if (!swapped && _override == null) return _seekbar();
    return Stack(
      children: [
        _seekbar(),
        Positioned(
          top: 0,
          right: AppSpacing.xl,
          child: _BackToMixChip(
            onTap: () => setState(() => _override = _MixDisplay.mix),
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

  Widget _mix(MixPair pair, Duration now, {required bool swapped}) {
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
      prepLine: pair.prepLine,
      height: widget.mixHeight,
      curve: recipe.curve,
      bassSwap: recipe.bassSwap,
      note: recipe.auto ? 'おまかせ: ${recipe.summary}' : null,
      onSeek: (t) => _seekInMix(pair, t, swapped: swapped),
      onShowFull: () => setState(() => _override = _MixDisplay.full),
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
