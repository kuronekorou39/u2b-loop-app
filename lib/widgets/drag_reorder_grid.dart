import 'package:flutter/material.dart';

import 'reorder_handle.dart';

/// 並べ替えモードのあるグリッド。[reordering] の間だけ、タイルに触れるとほぼすぐ持ち上がり、
/// 動かすと並べ替えられる（動かしている間は並びを先に見せ、離したときに [onReorder]）。
/// ふだんは [itemBuilder] のタイルをそのまま並べるだけ（タップ・長押しはタイル側）
class DragReorderGrid<T> extends StatefulWidget {
  const DragReorderGrid({
    super.key,
    required this.items,
    required this.idOf,
    required this.reordering,
    required this.gridDelegate,
    required this.itemBuilder,
    required this.onReorder,
    this.padding,
  });

  final List<T> items;
  final String Function(T) idOf;
  final bool reordering;
  final SliverGridDelegate gridDelegate;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// [newIndex] は動かした後の位置（ReorderableListView の onReorderItem と同じ）
  final void Function(int oldIndex, int newIndex) onReorder;
  final EdgeInsetsGeometry? padding;

  @override
  State<DragReorderGrid<T>> createState() => _DragReorderGridState<T>();
}

class _DragReorderGridState<T> extends State<DragReorderGrid<T>> {
  /// ドラッグ中の並び（離すまで保存しない）
  List<T>? _preview;

  int _indexIn(List<T> list, String id) =>
      list.indexWhere((e) => widget.idOf(e) == id);

  void _moveOver(String draggedId, String targetId) {
    final preview = _preview;
    if (preview == null || draggedId == targetId) return;
    final from = _indexIn(preview, draggedId);
    final to = _indexIn(preview, targetId);
    if (from < 0 || to < 0) return;
    setState(() => preview.insert(to, preview.removeAt(from)));
  }

  void _endDrag(String id) {
    final preview = _preview;
    setState(() => _preview = null);
    if (preview == null) return;
    final oldIndex = _indexIn(widget.items, id);
    final newIndex = _indexIn(preview, id);
    if (oldIndex < 0 || newIndex < 0) return;
    if (oldIndex != newIndex) widget.onReorder(oldIndex, newIndex);
  }

  @override
  Widget build(BuildContext context) {
    final items = _preview ?? widget.items;
    return GridView.builder(
      padding: widget.padding,
      gridDelegate: widget.gridDelegate,
      itemCount: items.length,
      // 並びが変わっても同じ項目の部品を使い続ける（動かしている項目が作り直されると
      // ドラッグの終わりが届かない）
      findChildIndexCallback: (key) {
        final i = items.indexWhere((e) => ValueKey(widget.idOf(e)) == key);
        return i < 0 ? null : i;
      },
      itemBuilder: (context, i) {
        final item = items[i];
        final id = widget.idOf(item);
        if (!widget.reordering) {
          return KeyedSubtree(
              key: ValueKey(id), child: widget.itemBuilder(context, item));
        }
        return DragTarget<String>(
          key: ValueKey(id),
          onWillAcceptWithDetails: (d) {
            _moveOver(d.data, id);
            return true;
          },
          builder: (context, _, _) => LayoutBuilder(
            builder: (context, constraints) {
              final tile = widget.itemBuilder(context, item);
              return LongPressDraggable<String>(
                data: id,
                delay: reorderTouchDelay,
                onDragStarted: () =>
                    setState(() => _preview = List.of(widget.items)),
                onDragEnd: (_) => _endDrag(id),
                feedback: Material(
                  type: MaterialType.transparency,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Transform.scale(scale: 1.06, child: tile),
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.3, child: tile),
                child: tile,
              );
            },
          ),
        );
      },
    );
  }
}
