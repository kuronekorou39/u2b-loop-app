import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 並べ替えのつまみ（≡）。触れた時点で行を持ち上げる。
///
/// 標準の [ReorderableDragStartListener] は指が動くまでドラッグを確定しないので、
/// つまみを押したまま止まっていると行の長押し（複数選択）が先に勝ってしまう。
/// つまみの上では、すぐ動かしても長押ししても並べ替えになるようにする
class ReorderHandle extends ReorderableDragStartListener {
  ReorderHandle({
    super.key,
    required super.index,
    super.enabled,
    EdgeInsetsGeometry padding = const EdgeInsets.all(AppSpacing.sm),
  }) : super(
          child: Builder(
            builder: (context) => Padding(
              padding: padding,
              child: Icon(Icons.drag_handle,
                  size: AppIconSizes.md, color: AppTheme.muted(context)),
            ),
          ),
        );

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      DelayedMultiDragGestureRecognizer(delay: Duration.zero, debugOwner: this);
}
