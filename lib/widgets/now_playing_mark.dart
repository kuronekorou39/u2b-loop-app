import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../providers/mini_player_provider.dart';
import '../providers/player_provider.dart';

/// ミニプレイヤーで鳴っている曲とプレイリスト（一覧で目印を出す）。鳴らしていなければ両方 null。
/// プレイリストの曲が進むとミニプレイヤーの曲が変わるので、目印もそれについて動く
final nowPlayingProvider = Provider<({String? itemId, String? playlistId})>((ref) {
  final mini = ref.watch(miniPlayerProvider);
  if (!mini.active || mini.item == null) return (itemId: null, playlistId: null);
  return (itemId: mini.item!.id, playlistId: mini.playlistId);
});

/// サムネの上に重ねる「鳴っている」目印（暗い膜の上で 3 本の棒が上下する。止めていれば止まる）。
/// [itemId] か [playlistId] が鳴っているものと同じときだけ出す。それ以外は何も描かない
/// （重ねるだけなので、出ても消えても一覧の並びは動かない）
class NowPlayingMark extends ConsumerWidget {
  const NowPlayingMark({super.key, this.itemId, this.playlistId, this.size = 16});

  final String? itemId;
  final String? playlistId;

  /// 棒の高さ（px）
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowPlayingProvider);
    final match = (itemId != null && itemId == now.itemId) ||
        (playlistId != null && playlistId == now.playlistId);
    if (!match) return const SizedBox.shrink();
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.5),
          child: Center(child: EqualizerBars(playing: playing, size: size)),
        ),
      ),
    );
  }
}

/// 3 本の棒が上下する「再生中」のアイコン。[playing] でなければ低い位置で止まる
class EqualizerBars extends StatefulWidget {
  const EqualizerBars({super.key, required this.playing, this.size = 16});

  final bool playing;
  final double size;

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(EqualizerBars old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value * 2 * pi;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final phase in const [0.0, 2.1, 4.2])
                Container(
                  width: s / 4.5,
                  // 止めているときは低い位置で揃える
                  height: widget.playing
                      ? s * (0.35 + 0.65 * (0.5 + 0.5 * sin(t + phase)))
                      : s * 0.35,
                  decoration: BoxDecoration(
                    color: AppTheme.accentGreen,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
