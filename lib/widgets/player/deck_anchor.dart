import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// デッキの板（[MixDeck]）を出す場所。画面の側が置き場所を用意すると、板は波形の上に
/// 浮かせず、そこに大きく出す（横画面: 左の列の動画の上、全画面: 下の板の左半分）。
/// 無ければ（縦画面）今まで通り波形の上に浮かせる。
///
/// 板を出しているかは [open] で画面の側に知らせる（横画面は動画を暗く、全画面は
/// 下の板を左右に分ける）。
class DeckAnchorController {
  /// 置き場所（画面の側が [CompositedTransformTarget] で置く）
  final link = LayerLink();

  /// 板を出しているか（シークバーの側が書く）
  final open = ValueNotifier(false);

  /// 置き場所の大きさ（画面の側が組むときに書く）。板はこの大きさで組み、
  /// [room] に収まるよう縮めて描く
  Size size = Size.zero;

  /// 置き場所の今の大きさ（[DeckAnchorTarget] が測る）。開くときに伸びる途中も
  /// これに合わせるので、板が置き場所の外へ飛び出さない
  final room = ValueNotifier(Size.zero);

  /// 置き場所が他のもの（トラック一覧など）に使われている間は出さない
  bool suppressed = false;

  bool _disposed = false;
  bool get disposed => _disposed;

  /// 板の出し入れを知らせる（捨てた後は何もしない）
  void setOpen(bool value) {
    if (_disposed || open.value == value) return;
    open.value = value;
  }

  void dispose() {
    _disposed = true;
    open.dispose();
    room.dispose();
  }
}

/// [DeckAnchorController] を持ち、子孫に渡す
class DeckAnchorScope extends StatefulWidget {
  const DeckAnchorScope({super.key, required this.builder});

  final Widget Function(BuildContext context, DeckAnchorController anchor)
      builder;

  /// 近くの置き場所。無ければ null（板は波形の上に浮かせる）
  static DeckAnchorController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_DeckAnchorScope>()
      ?.controller;

  @override
  State<DeckAnchorScope> createState() => _DeckAnchorScopeState();
}

class _DeckAnchorScopeState extends State<DeckAnchorScope> {
  final _controller = DeckAnchorController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _DeckAnchorScope(
        controller: _controller,
        child: Builder(builder: (context) => widget.builder(context, _controller)),
      );
}

class _DeckAnchorScope extends InheritedWidget {
  const _DeckAnchorScope({required this.controller, required super.child});

  final DeckAnchorController controller;

  @override
  bool updateShouldNotify(_DeckAnchorScope old) => old.controller != controller;
}

/// 置き場所の目印（画面の側が板を出したい所に敷く）。大きさは親に合わせる
class DeckAnchorTarget extends StatelessWidget {
  const DeckAnchorTarget({super.key, required this.anchor});

  final DeckAnchorController anchor;

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
        link: anchor.link,
        child: _MeasureSize(anchor: anchor, child: const SizedBox.expand()),
      );
}

/// 組んだ大きさを [DeckAnchorController.room] に知らせる（描いた後。組んでいる最中に
/// 知らせると板の描き直しと重なる）
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.anchor, super.child});

  final DeckAnchorController anchor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(anchor);

  @override
  void updateRenderObject(
          BuildContext context, _RenderMeasureSize renderObject) =>
      renderObject.anchor = anchor;
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.anchor);

  DeckAnchorController anchor;

  @override
  void performLayout() {
    super.performLayout();
    final measured = size;
    final target = anchor;
    if (target.disposed || target.room.value == measured) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!target.disposed) target.room.value = measured;
    });
    // 次のフレームを確実に起こす（アニメーションが止まった直後でも反映する）
    WidgetsBinding.instance.scheduleFrame();
  }
}
