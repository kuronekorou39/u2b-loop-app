import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 行のすぐ上か下に出す小さなメニュー（ポップオーバー）の土台。
///
/// 元の行（[anchorRect]）は明るいまま残し、ほかを少し暗くする。どの行のメニューかが
/// 見たまま分かるので、見出しに名前を出さなくて済む。下に入らなければ上に出す
class AnchoredMenuRoute<T> extends PopupRoute<T> {
  AnchoredMenuRoute({required this.anchorRect, required this.builder});

  /// 元の行の場所（Navigator の中の座標）
  final Rect anchorRect;
  final WidgetBuilder builder;

  /// メニューの幅（画面が狭ければ画面に合わせて縮む）
  static const menuWidth = 260.0;

  /// 行とメニューの間
  static const _gap = 6.0;

  /// 画面の端との間
  static const _margin = AppSpacing.lg;

  @override
  Color? get barrierColor => null; // 暗い膜は行の形に穴を開けて自前で描く

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '閉じる';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return _CloseOnResize(
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: FadeTransition(
                opacity: fade,
                child: CustomPaint(painter: _SpotlightPainter(anchorRect)),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _MenuLayout(
                anchor: anchorRect,
                safe: MediaQuery.paddingOf(context),
              ),
              child: FadeTransition(
                opacity: fade,
                child: ScaleTransition(
                  scale: Tween(begin: 0.96, end: 1.0).animate(fade),
                  alignment: Alignment.centerRight,
                  child: Material(
                    elevation: 8,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: Builder(builder: builder),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 画面の大きさが変わったら（回転など）閉じる。行の場所は開いた時点のものなので、
/// 残すと穴とメニューがずれる
class _CloseOnResize extends StatefulWidget {
  const _CloseOnResize({required this.child});

  final Widget child;

  @override
  State<_CloseOnResize> createState() => _CloseOnResizeState();
}

class _CloseOnResizeState extends State<_CloseOnResize> {
  Size? _size;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    if (_size != null && _size != size) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    _size = size;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 行の下（入らなければ上）、右端を行の右に寄せて置く
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout({required this.anchor, required this.safe});

  final Rect anchor;
  final EdgeInsets safe;

  static const _gap = AnchoredMenuRoute._gap;
  static const _margin = AnchoredMenuRoute._margin;

  double _below(Size size) =>
      size.height - safe.bottom - _margin - (anchor.bottom + _gap);

  double _above() => anchor.top - _gap - safe.top - _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final width = math.min(AnchoredMenuRoute.menuWidth,
        size.width - safe.horizontal - _margin * 2);
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      // 上下の広い方に入る高さまで（超える分はメニューの中でスクロール）
      maxHeight: math.max(48.0, math.max(_below(size), _above())),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minX = safe.left + _margin;
    final maxX = size.width - safe.right - _margin - childSize.width;
    final x = (anchor.right - AppSpacing.sm - childSize.width)
        .clamp(minX, math.max(minX, maxX))
        .toDouble();
    final below = childSize.height <= _below(size) || _below(size) >= _above();
    final y = below
        ? anchor.bottom + _gap
        : anchor.top - _gap - childSize.height;
    final minY = safe.top + _margin;
    final maxY = size.height - safe.bottom - _margin - childSize.height;
    return Offset(x, y.clamp(minY, math.max(minY, maxY)).toDouble());
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      old.anchor != anchor || old.safe != safe;
}

/// 行の形に穴を開けた暗い膜 + 行の縁取り
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter(this.anchor);

  final Rect anchor;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(anchor, const Radius.circular(10));
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(hole),
      Paint()..color = const Color(0x8C000000),
    );
    canvas.drawRRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0x59FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.anchor != anchor;
}
