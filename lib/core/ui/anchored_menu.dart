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
                    // 画面の端の余白はメニューの置き場所で避けてある。残すと横画面で
                    // ListTile が中身をその分ずらし、文字が折り返す
                    child: MediaQuery.removePadding(
                      context: context,
                      removeLeft: true,
                      removeRight: true,
                      child: Builder(builder: builder),
                    ),
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

/// 行の下（入らなければ上）、右端を行の右に寄せて置く。
/// 横画面のボタン（メニューより幅の狭いもの）は高さが足りないので、左（入らなければ右）の脇に置く
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout({required this.anchor, required this.safe});

  final Rect anchor;
  final EdgeInsets safe;

  static const _gap = AnchoredMenuRoute._gap;
  static const _margin = AnchoredMenuRoute._margin;

  double _below(Size size) =>
      size.height - safe.bottom - _margin - (anchor.bottom + _gap);

  double _above() => anchor.top - _gap - safe.top - _margin;

  double _leftRoom() => anchor.left - _gap - safe.left - _margin;

  double _rightRoom(Size size) =>
      size.width - safe.right - _margin - anchor.right - _gap;

  double _menuWidth(Size size) => math.min(
      AnchoredMenuRoute.menuWidth, size.width - safe.horizontal - _margin * 2);

  bool _beside(Size size) {
    if (size.width <= size.height) return false;
    if (anchor.width > AnchoredMenuRoute.menuWidth) return false;
    final width = _menuWidth(size);
    return _leftRoom() >= width || _rightRoom(size) >= width;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final width = _menuWidth(size);
    if (_beside(size)) {
      return BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: math.max(48.0, size.height - safe.vertical - _margin * 2),
      );
    }
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
    final minY = safe.top + _margin;
    final maxY = size.height - safe.bottom - _margin - childSize.height;
    if (_beside(size)) {
      final sideX = _leftRoom() >= childSize.width
          ? anchor.left - _gap - childSize.width
          : anchor.right + _gap;
      return Offset(
          sideX, anchor.top.clamp(minY, math.max(minY, maxY)).toDouble());
    }
    final x = (anchor.right - AppSpacing.sm - childSize.width)
        .clamp(minX, math.max(minX, maxX))
        .toDouble();
    final below = childSize.height <= _below(size) || _below(size) >= _above();
    final y = below
        ? anchor.bottom + _gap
        : anchor.top - _gap - childSize.height;
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
