import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_item.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../item_thumbnail.dart';
import '../lyrics_overlay.dart';
import 'video_player_widget.dart';

/// プレイリスト再生画面の動画領域。曲が切り替わるときに DJ アプリ風の演出をする。
///
/// 1. クロスフェード中（[crossfadeProgressProvider] が 0→1）: 再生中の動画が
///    カメラを引くように左へ縮み、右に次曲のサムネが現れる
/// 2. スロット入替（[activeSlotProvider] の変化）: 新しい動画が右の小さな枠から
///    全画面へズームインし、前曲のサムネは左で消えていく
///
/// クロスフェードがオフのときは 1 を飛ばして 2 だけ起きるので、
/// どの設定でも切り替わりがアニメーションになる。
class TransitionStage extends ConsumerStatefulWidget {
  const TransitionStage({
    super.key,
    required this.currentItem,
    this.onFullscreen,
  });

  /// プレイリストの現在のトラックのアイテム
  final LoopItem currentItem;
  final VoidCallback? onFullscreen;

  @override
  ConsumerState<TransitionStage> createState() => _TransitionStageState();
}

class _TransitionStageState extends ConsumerState<TransitionStage>
    with SingleTickerProviderStateMixin {
  /// 縮んだときの枠の大きさ（全体に対する比率）
  static const _smallScale = 0.46;

  /// 縮んだ枠の中心位置（横方向、0〜1）
  static const _leftCenter = 0.26;
  static const _rightCenter = 0.74;

  static const _zoomInDuration = Duration(milliseconds: 600);

  /// クロスフェードの進捗は 100ms 刻みで届くので、その間を補間する
  static const _progressSmoothing = Duration(milliseconds: 160);

  late final AnimationController _zoomIn =
      AnimationController(vsync: this, duration: _zoomInDuration);

  /// いま動画ウィジェットに映っているはずのアイテム。
  /// プレイリスト側の currentTrack は swapSlots より先に進むため、
  /// 「前の曲」はこれから取る（スロット入替の通知時点ではまだ更新前）
  LoopItem? _displayed;

  /// ズームイン中に左で消えていく前曲
  LoopItem? _outgoing;

  @override
  void initState() {
    super.initState();
    _displayed = widget.currentItem;
    _zoomIn.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _outgoing = null);
      }
    });
  }

  @override
  void didUpdateWidget(TransitionStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentItem.id != oldWidget.currentItem.id) {
      _displayed = widget.currentItem;
    }
  }

  @override
  void dispose() {
    _zoomIn.dispose();
    super.dispose();
  }

  void _onSlotChanged() {
    if (!mounted) return;
    setState(() {
      final prev = _displayed;
      _outgoing = prev?.id == widget.currentItem.id ? null : prev;
    });
    _zoomIn.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeSlotProvider, (_, _) => _onSlotChanged());
    final crossfade = ref.watch(crossfadeProgressProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return TweenAnimationBuilder<double>(
          tween: Tween(end: crossfade?.progress ?? 0),
          duration: _progressSmoothing,
          builder: (context, out, _) => AnimatedBuilder(
            animation: _zoomIn,
            builder: (context, _) =>
                _buildStage(size, out, crossfade?.next),
          ),
        );
      },
    );
  }

  Widget _buildStage(Size size, double out, LoopItem? next) {
    final w = size.width;
    final h = size.height;
    final full = Offset.zero & size;
    Rect small(double cx, [double scale = _smallScale]) => Rect.fromCenter(
          center: Offset(w * cx, h / 2),
          width: w * scale,
          height: h * scale,
        );
    final left = small(_leftCenter);
    final right = small(_rightCenter);

    final zooming = _zoomIn.status == AnimationStatus.forward;
    final zoom = Curves.easeOutCubic.transform(_zoomIn.value);

    final Rect videoRect;
    if (zooming) {
      videoRect = Rect.lerp(right, full, zoom)!;
    } else if (out > 0) {
      videoRect = Rect.lerp(full, left, Curves.easeInOut.transform(out))!;
    } else {
      videoRect = full;
    }
    // 全画面では角丸なし、縮むほど丸く
    final shrink = ((1 - videoRect.width / w) / (1 - _smallScale)).clamp(0.0, 1.0);
    final radius = Radius.circular(AppRadius.lg * shrink);

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.black)),
        // 前曲（ズームイン中に左で消える）
        if (zooming && _outgoing != null)
          Positioned.fromRect(
            rect: left,
            child: Opacity(
              opacity: 1 - zoom,
              child: _ThumbCard(item: _outgoing!),
            ),
          ),
        // 次曲（クロスフェード中に右へ現れる）
        if (!zooming && out > 0 && next != null)
          Positioned.fromRect(
            rect: small(_rightCenter, _smallScale * (0.8 + 0.2 * out)),
            child: Opacity(
              opacity: out,
              child: _ThumbCard(item: next, label: '次'),
            ),
          ),
        Positioned.fromRect(
          rect: videoRect,
          child: ClipRRect(
            borderRadius: BorderRadius.all(radius),
            child: VideoPlayerWidget(
              useAspectRatio: false,
              onFullscreen: widget.onFullscreen,
            ),
          ),
        ),
        const Positioned.fill(child: LyricsOverlay()),
      ],
    );
  }
}

/// 縮んだ枠に出すサムネ（角丸・薄い枠線・任意のラベル）
class _ThumbCard extends StatelessWidget {
  const _ThumbCard({required this.item, this.label});

  final LoopItem item;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadius.borderLg,
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ItemThumbnail(item: item, iconSize: AppIconSizes.xl),
          if (label != null)
            Positioned(
              left: AppSpacing.md,
              top: AppSpacing.md,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.accentGreen.withValues(alpha: 0.85),
                  borderRadius: AppRadius.borderXs,
                ),
                child: Text(
                  label!,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.darkBackground,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
