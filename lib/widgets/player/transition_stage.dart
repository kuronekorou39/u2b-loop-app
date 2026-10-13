import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../models/loop_item.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlist_engine.dart';
import '../item_thumbnail.dart';
import '../lyrics_overlay.dart';
import 'video_player_widget.dart';

/// プレイリスト再生画面の動画領域。曲が切り替わるときに DJ の 2 デッキ風の演出をする。
///
/// 1. クロスフェード開始: 0.35 秒のバネっぽい動きで、再生中の動画が左の枠に縮み、
///    右に次曲のサムネが出る（2 デッキ配置）。そのまま横並びで待つ
/// 2. 横並びの間: 旧曲の枠の大きさ・明るさは実際の音量曲線（cos）に、
///    次曲の枠は sin に追従する。絵がそのままミックスの状態を表す
/// 3. スロット入替: 新しい動画が右の枠から 0.3 秒で全画面へポンと寄る。
///    前曲のサムネは左で消える
///
/// クロスフェードがオフのときは 1〜2 を飛ばして 3 だけ起きる。
/// 交差が取り消されたら（一時停止・巻き戻し）1 を逆再生して全画面に戻す。
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
    with TickerProviderStateMixin {
  /// 縮んだときの枠の大きさ（全体に対する比率）
  static const _smallScale = 0.46;

  /// 縮んだ枠の中心位置（横方向、0〜1）
  static const _leftCenter = 0.26;
  static const _rightCenter = 0.74;

  static const _deckDuration = Duration(milliseconds: 350);
  static const _zoomInDuration = Duration(milliseconds: 300);

  /// クロスフェードの進捗は 100ms 刻みで届くので、その間を補間する
  static const _progressSmoothing = Duration(milliseconds: 160);

  /// 全画面 → 2 デッキ配置（行き過ぎて戻るバネ）
  late final AnimationController _deck =
      AnimationController(vsync: this, duration: _deckDuration);

  /// 右の枠 → 全画面
  late final AnimationController _zoomIn =
      AnimationController(vsync: this, duration: _zoomInDuration);

  /// いま動画ウィジェットに映っているはずのアイテム。
  /// プレイリスト側の currentTrack は swapSlots より先に進むため、
  /// 「前の曲」はこれから取る（スロット入替の通知時点ではまだ更新前）
  LoopItem? _displayed;

  /// ズームイン中に左で消えていく前曲
  LoopItem? _outgoing;

  /// 交差が終わった後もサムネを描き続けるために覚えておく次曲
  LoopItem? _next;

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
    _deck.dispose();
    _zoomIn.dispose();
    super.dispose();
  }

  void _onSlotChanged() {
    if (!mounted) return;
    setState(() {
      final prev = _displayed;
      _outgoing = prev?.id == widget.currentItem.id ? null : prev;
    });
    // デッキ配置はズームインに置き換わるので、アニメーションせずに畳む
    _deck.value = 0;
    _zoomIn.forward(from: 0);
  }

  void _onCrossfadeChanged(CrossfadeProgress? prev, CrossfadeProgress? next) {
    if (!mounted) return;
    if (prev == null && next != null) {
      setState(() => _next = next.next);
      _deck.forward();
    } else if (prev != null && next == null) {
      // スワップ由来なら _onSlotChanged が先に畳んでいる。取り消しなら戻す
      if (_zoomIn.status != AnimationStatus.forward && _deck.value > 0) {
        _deck.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeSlotProvider, (_, _) => _onSlotChanged());
    ref.listen<CrossfadeProgress?>(
        crossfadeProgressProvider, _onCrossfadeChanged);
    final crossfade = ref.watch(crossfadeProgressProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return TweenAnimationBuilder<double>(
          tween: Tween(end: crossfade?.progress ?? 0),
          duration: _progressSmoothing,
          builder: (context, progress, _) => AnimatedBuilder(
            animation: Listenable.merge([_deck, _zoomIn]),
            builder: (context, _) => _buildStage(size, progress),
          ),
        );
      },
    );
  }

  Widget _buildStage(Size size, double progress) {
    final w = size.width;
    final h = size.height;
    final full = Offset.zero & size;
    Rect small(double cx, [double scale = _smallScale]) => Rect.fromCenter(
          center: Offset(w * cx, h / 2),
          width: w * scale,
          height: h * scale,
        );

    // 音量曲線（等パワー）。横並びの間、枠の大きさと明るさをこれに追従させる
    final angle = progress * pi / 2;
    final outLevel = cos(angle);
    final inLevel = sin(angle);

    final zooming = _zoomIn.status == AnimationStatus.forward;
    final zoom = Curves.easeOutBack.transform(_zoomIn.value);
    final deck = Curves.easeOutBack.transform(_deck.value);
    final inDeck = !zooming && _deck.value > 0;

    final left = small(_leftCenter, _smallScale * (0.88 + 0.12 * outLevel));
    final right = small(_rightCenter, _smallScale * (0.88 + 0.12 * inLevel));

    final Rect videoRect;
    if (zooming) {
      videoRect = Rect.lerp(small(_rightCenter), full, zoom)!;
    } else if (inDeck) {
      videoRect = Rect.lerp(full, left, deck)!;
    } else {
      videoRect = full;
    }
    // 全画面では角丸なし、縮むほど丸く
    final shrink = ((1 - videoRect.width / w) / (1 - _smallScale)).clamp(0.0, 1.0);
    final radius = Radius.circular(AppRadius.lg * shrink);
    // 横並びの間、旧曲は音量が落ちるにつれて暗くなる
    final dim = inDeck ? (1 - outLevel) * 0.6 * _deck.value.clamp(0.0, 1.0) : 0.0;

    final next = _next;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.black)),
        // 前曲（ズームイン中に左で消える）
        if (zooming && _outgoing != null)
          Positioned.fromRect(
            rect: small(_leftCenter),
            child: Opacity(
              opacity: (1 - _zoomIn.value).clamp(0.0, 1.0),
              child: _ThumbCard(item: _outgoing!),
            ),
          ),
        // 次曲（2 デッキ配置で右に出る。音量が上がるにつれて大きく明るく）
        if (inDeck && next != null)
          Positioned.fromRect(
            rect: right,
            child: Opacity(
              opacity: (_deck.value * (0.35 + 0.65 * inLevel)).clamp(0.0, 1.0),
              child: _ThumbCard(item: next, label: '次'),
            ),
          ),
        Positioned.fromRect(
          rect: videoRect,
          child: ClipRRect(
            borderRadius: BorderRadius.all(radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                VideoPlayerWidget(
                  useAspectRatio: false,
                  onFullscreen: widget.onFullscreen,
                ),
                if (dim > 0)
                  IgnorePointer(
                    child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
                  ),
              ],
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
